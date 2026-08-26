import Foundation

struct SessionUpdate {
    var sessionUpdate: String
    var text: String?
    var toolTitle: String?
    var toolStatus: String?
    var raw: [String: Any]
}

final class AcpClient: @unchecked Sendable {
    var onUpdate: (@Sendable (AcpUpdateDelivery) -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    var onExit: (@Sendable (Int32) -> Void)?

    private let queue = DispatchQueue(label: "local.bubble.acp")
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var buffer = Data()
    private var nextId = 1
    private var pending: [RPCID: CheckedContinuation<Any?, Error>] = [:]
    private var inFlightPrompt: [String: RPCID] = [:]
    private let controlFile: URL

    init(controlFile: URL = OverlayPaths.controlFile) {
        self.controlFile = controlFile
    }

    private(set) var sessionId: String?
    private(set) var canLoad = false
    private(set) var canResume = false
    private(set) var canList = false
    private(set) var availableModels: [AgentModel] = []
    private(set) var currentModelId: String?
    private(set) var thinkingLevels: [String] = BubbleConfig.defaultThinkingLevels
    private(set) var currentThinking: String?
    var onConfigChange: (@Sendable () -> Void)?
    private var isReplaying = false

    func isRunning() -> Bool {
        queue.sync { process?.isRunning == true }
    }

    func start() throws {
        try queue.sync {
            if process?.isRunning == true { return }
            OverlayPaths.bootstrap()

            guard BubblePiRuntimePatch.isApplied(runtime: OverlayPaths.runtime) else {
                throw RPCError(code: -1, message: "pi not found. Type /setup to install it into ~/.bubble/runtime.")
            }
            guard BubblePiAcpPatch.isApplied(runtime: OverlayPaths.runtime) else {
                throw RPCError(code: -1, message: "Bubble's branch adapter is missing. Type /setup to install it into ~/.bubble/runtime.")
            }
            guard let launch = OverlayPaths.resolveAgentLaunch() else {
                throw RPCError(code: -1, message: "pi-acp not found. Type /setup to install it into ~/.bubble/runtime.")
            }

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let process = Process()
            process.executableURL = launch.executable
            process.arguments = launch.arguments
            process.currentDirectoryURL = OverlayPaths.workspace
            process.environment = OverlayPaths.processEnvironment(controlFile: controlFile)
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdout = stdoutPipe.fileHandleForReading
            let stderr = stderrPipe.fileHandleForReading
            stdout.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                self?.queue.async { self?.consume(data) }
            }
            stderr.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                self?.onLog?(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            self.stdout = stdout
            self.stderr = stderr

            process.terminationHandler = { [weak self] proc in
                self?.queue.async {
                    self?.failAll(RPCError(code: -2, message: "pi-acp exited (\(proc.terminationStatus))"))
                    self?.resetProcessLocked()
                    self?.onExit?(proc.terminationStatus)
                }
            }

            OverlayLog.write("starting \(launch.executable.path) \(launch.arguments.joined(separator: " ")) in \(OverlayPaths.workspace.path)")
            try process.run()
            self.process = process
            self.stdin = stdinPipe.fileHandleForWriting
            self.buffer.removeAll(keepingCapacity: true)
        }
    }

    func stop() {
        queue.sync {
            process?.terminationHandler = nil
            stdin = nil
            process?.terminate()
            resetProcessLocked()
            failAll(RPCError(code: -3, message: "stopped"))
        }
    }

    func connectAndResume() async throws -> String {
        if !isRunning() {
            try start()
        }
        try await initialize()
        let id = try await ensureSession()
        try? await applyBubblePreferences()
        return id
    }

    func reconnectSideSession() async throws -> String {
        let existing = sessionId
        if !isRunning() {
            try start()
        }
        try await initialize()
        if let existing, try await attach(existing, cwd: OverlayPaths.workspace) {
            try? await applyBubblePreferences()
            return existing
        }
        let created = try await newSession(cwd: OverlayPaths.workspace, persistAsMain: false)
        sessionId = created
        try? await applyBubblePreferences()
        return created
    }

    func switchToSession(_ id: String, persistAsMain: Bool = true) async throws -> String {
        if !isRunning() {
            try start()
            try await initialize()
        }
        if try await attach(id, cwd: OverlayPaths.workspace) {
            sessionId = id
            if persistAsMain {
                persistSessionId(id)
            }
            try? await applyBubblePreferences()
            return id
        }
        throw RPCError(code: -6, message: "Could not resume session \(id).")
    }

    func listSessionIds() async throws -> [String] {
        guard canList else { return [] }
        let result = try await request("session/list", params: [
            "cwd": OverlayPaths.workspace.path,
        ])
        let object = JSONValue.object(result) ?? [:]
        let sessions = object.array("sessions") ?? []
        return sessions.compactMap { item in
            let row = JSONValue.object(item) ?? [:]
            return row.string("sessionId") ?? row.string("id")
        }
    }

    func startFreshSession(persistAsMain: Bool = true) async throws -> String {
        if !isRunning() {
            try start()
            try await initialize()
        }
        let created = try await newSession(cwd: OverlayPaths.workspace, persistAsMain: persistAsMain)
        sessionId = created
        if persistAsMain {
            persistSessionId(created)
        }
        try? await applyBubblePreferences()
        return created
    }

    func setConfigOption(id: String, value: String, sessionId override: String? = nil) async throws {
        guard let sessionId = override ?? sessionId else {
            throw RPCError(code: -4, message: "no session")
        }
        let result = try await request("session/set_config_option", params: [
            "sessionId": sessionId,
            "configId": id,
            "value": value,
        ])
        ingestConfiguration(result)
        if id == "model" {
            currentModelId = value
        } else if id == "thought_level" {
            currentThinking = value
        }
        notifyConfigChange()
    }

    func applyBubblePreferences(sessionId override: String? = nil) async throws {
        let settings = BubbleConfig.load()
        if let model = settings.modelIdentity, override != nil || model != currentModelId {
            if availableModels.isEmpty || availableModels.contains(where: { $0.identity == model }) {
                try await setConfigOption(id: "model", value: model, sessionId: override)
            } else {
                OverlayLog.write("bubble model \(model) is not in the session catalog")
            }
        }
        if let thinking = settings.thinking, override != nil || thinking != currentThinking {
            try await setConfigOption(id: "thought_level", value: thinking, sessionId: override)
        }
    }

    func prompt(
        _ text: String,
        attachments: [PromptAttachment] = [],
        images: [PromptImage] = [],
        sessionId override: String? = nil
    ) async throws -> String {
        guard let sessionId = override ?? sessionId else {
            throw RPCError(code: -4, message: "no session")
        }
        var blocks: [[String: Any]] = [["type": "text", "text": text]]
        for attachment in attachments {
            blocks.append([
                "type": "resource_link",
                "uri": attachment.uri,
                "name": attachment.name,
            ])
        }
        for image in images {
            blocks.append([
                "type": "image",
                "mimeType": image.mimeType,
                "data": image.data.base64EncodedString(),
            ])
        }
        let result = try await request("session/prompt", params: [
            "sessionId": sessionId,
            "prompt": blocks,
        ])
        let object = JSONValue.object(result) ?? [:]
        return object.string("stopReason") ?? "end_turn"
    }

    func conversationTree(sessionId override: String? = nil) async throws -> ConversationTreeSnapshot {
        guard let sessionId = override ?? sessionId else {
            throw RPCError(code: -4, message: "no session")
        }
        let result = try await request("_bubble/session/tree", params: [
            "sessionId": sessionId,
        ])
        guard let snapshot = ConversationTreeSnapshot(response: result) else {
            throw RPCError(code: -7, message: "Pi returned an unreadable conversation tree.")
        }
        return snapshot
    }

    func navigateConversation(
        to targetID: String,
        sessionId override: String? = nil
    ) async throws -> ConversationTreeSnapshot {
        guard let sessionId = override ?? sessionId else {
            throw RPCError(code: -4, message: "no session")
        }
        let result = try await request("_bubble/session/navigate_tree", params: [
            "sessionId": sessionId,
            "targetId": targetID,
        ])
        guard let snapshot = ConversationTreeSnapshot(response: result) else {
            throw RPCError(code: -7, message: "Pi returned an unreadable conversation tree.")
        }
        return snapshot
    }

    func selectConversationLeaf(
        _ targetID: String,
        sessionId override: String? = nil
    ) async throws -> ConversationTreeSnapshot {
        guard let sessionId = override ?? sessionId else {
            throw RPCError(code: -4, message: "no session")
        }
        let result = try await request("_bubble/session/select_leaf", params: [
            "sessionId": sessionId,
            "targetId": targetID,
        ])
        guard let snapshot = ConversationTreeSnapshot(response: result) else {
            throw RPCError(code: -7, message: "Pi returned an unreadable conversation tree.")
        }
        return snapshot
    }

    func cancel(sessionId override: String? = nil) {
        guard let sessionId = override ?? sessionId else { return }
        queue.async { [weak self] in
            guard let self else { return }
            OverlayLog.write("session/cancel \(sessionId)")
            self.write([
                "jsonrpc": "2.0",
                "method": "session/cancel",
                "params": ["sessionId": sessionId],
            ])
            if let id = self.inFlightPrompt.removeValue(forKey: sessionId),
               let continuation = self.pending.removeValue(forKey: id) {
                continuation.resume(returning: ["stopReason": "cancelled"])
            }
        }
    }

    func steer(_ text: String, images: [PromptImage] = []) async throws {
        guard let sessionId else {
            throw RPCError(code: -4, message: "no session")
        }
        try await SteeringControlClient.send(sessionId: sessionId, text: text, images: images)
    }

    func createSession(cwd: URL) async throws -> String {
        try await newSession(cwd: cwd, persistAsMain: false)
    }

    func attach(_ id: String, cwd: URL) async throws -> Bool {
        setReplaying(true)
        defer { setReplaying(false) }
        if canResume, (try? await resume(id, cwd: cwd)) != nil {
            OverlayLog.write("resumed \(id) cwd=\(cwd.path)")
            return true
        }
        if canLoad {
            do {
                try await load(id, cwd: cwd)
                OverlayLog.write("loaded \(id) cwd=\(cwd.path)")
                return true
            } catch {
                OverlayLog.write("load failed \(id): \(error.localizedDescription)")
            }
        }
        return false
    }

    private func setReplaying(_ replaying: Bool) {
        queue.sync {
            isReplaying = replaying
        }
    }

    private func initialize() async throws {
        let result = try await request("initialize", params: [
            "protocolVersion": 1,
            "clientInfo": [
                "name": "bubble",
                "title": "Bubble",
                "version": "0.1.0",
            ],
            "clientCapabilities": [:] as [String: Any],
        ])
        let object = JSONValue.object(result) ?? [:]
        let capabilities = object.dictionary("agentCapabilities") ?? [:]
        canLoad = JSONValue.advertised(capabilities["loadSession"])
        let sessionCaps = capabilities.dictionary("sessionCapabilities") ?? [:]
        canResume = JSONValue.advertised(sessionCaps["resume"])
        canList = JSONValue.advertised(sessionCaps["list"])
        OverlayLog.write("initialized load=\(canLoad) resume=\(canResume) list=\(canList)")
    }

    private func ensureSession() async throws -> String {
        let saved = (try? String(contentsOf: OverlayPaths.sessionIdFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let saved, !saved.isEmpty {
            if try await attach(saved, cwd: OverlayPaths.workspace) {
                sessionId = saved
                return saved
            }
        }
        if canList, let listed = try await latestListedSession(), try await attach(listed, cwd: OverlayPaths.workspace) {
            sessionId = listed
            persistSessionId(listed)
            return listed
        }
        let created = try await newSession(cwd: OverlayPaths.workspace, persistAsMain: true)
        sessionId = created
        persistSessionId(created)
        return created
    }

    private func newSession(cwd: URL, persistAsMain: Bool) async throws -> String {
        let result = try await request("session/new", params: [
            "cwd": cwd.path,
            "mcpServers": [] as [Any],
        ])
        let object = JSONValue.object(result) ?? [:]
        guard let id = object.string("sessionId"), !id.isEmpty else {
            throw RPCError(code: -5, message: "session/new did not return sessionId")
        }
        if persistAsMain {
            ingestConfiguration(object)
        }
        OverlayLog.write("created session \(id) cwd=\(cwd.path) model=\(currentModelId ?? "?")")
        return id
    }

    private func resume(_ id: String, cwd: URL) async throws {
        let result = try await request("session/resume", params: [
            "sessionId": id,
            "cwd": cwd.path,
            "mcpServers": [] as [Any],
        ])
        if id == sessionId {
            ingestConfiguration(result)
        }
    }

    private func load(_ id: String, cwd: URL) async throws {
        let result = try await request("session/load", params: [
            "sessionId": id,
            "cwd": cwd.path,
            "mcpServers": [] as [Any],
        ])
        if id == sessionId {
            ingestConfiguration(result)
        }
    }

    func ingestConfiguration(_ value: Any?) {
        let object = JSONValue.object(value) ?? [:]
        let options = object.array("configOptions") ?? []
        ingestConfigOptions(options)
        notifyConfigChange()
    }

    func ingestConfigOptions(_ options: [Any]) {
        for entry in options {
            guard let object = JSONValue.object(entry),
                  let id = object.string("id") else { continue }
            let current = object.string("currentValue")
            let values: [String] = (object.array("options") ?? []).compactMap { item in
                JSONValue.object(item)?.string("value")
            }
            switch id {
            case "model":
                let parsed: [AgentModel] = (object.array("options") ?? []).compactMap { item in
                    guard let option = JSONValue.object(item),
                          let value = option.string("value"), !value.isEmpty else {
                        return nil
                    }
                    return AgentModel.parse(value, name: option.string("name"))
                }
                if !parsed.isEmpty {
                    availableModels = parsed
                } else if !values.isEmpty {
                    availableModels = values.map { AgentModel.parse($0) }
                }
                if let current, !current.isEmpty {
                    currentModelId = current
                }
            case "thought_level":
                if !values.isEmpty {
                    thinkingLevels = values
                }
                if let current, !current.isEmpty {
                    currentThinking = current
                }
            default:
                break
            }
        }
        if availableModels.isEmpty {
            availableModels = BubbleConfig.catalogModels()
        }
    }

    private func notifyConfigChange() {
        onConfigChange?()
    }

    private func latestListedSession() async throws -> String? {
        let result = try await request("session/list", params: [
            "cwd": OverlayPaths.workspace.path,
        ])
        let object = JSONValue.object(result) ?? [:]
        let sessions = object.array("sessions") ?? []
        let ids = sessions.compactMap { JSONValue.object($0)?.string("sessionId") }
        return ids.first
    }

    private func setMode(_ modeId: String) async throws {
        guard let sessionId else { return }
        _ = try await request("session/set_mode", params: [
            "sessionId": sessionId,
            "modeId": modeId,
        ])
    }

    private func persistSessionId(_ id: String) {
        OverlayPaths.bootstrap()
        try? id.write(to: OverlayPaths.sessionIdFile, atomically: true, encoding: .utf8)
    }

    private func request(_ method: String, params: [String: Any]) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let id = RPCID.int(self.nextId)
                self.nextId += 1
                self.pending[id] = continuation
                if method == "session/prompt", let sid = params["sessionId"] as? String {
                    self.inFlightPrompt[sid] = id
                }
                self.write([
                    "jsonrpc": "2.0",
                    "id": id.jsonValue,
                    "method": method,
                    "params": params,
                ])
            }
        }
    }

    private func write(_ message: [String: Any]) {
        guard let stdin else {
            OverlayLog.write("write dropped, agent not running")
            return
        }
        do {
            var data = try JSONSerialization.data(withJSONObject: message, options: [])
            data.append(0x0A)
            try stdin.write(contentsOf: data)
        } catch {
            OverlayLog.write("write failed: \(error.localizedDescription)")
        }
    }

    private func consume(_ data: Data) {
        if data.isEmpty {
            return
        }
        buffer.append(data)
        while let range = buffer.range(of: Data([0x0A])) {
            let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(..<range.upperBound)
            guard !line.isEmpty else { continue }
            handleLine(line)
        }
    }

    private func handleLine(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            if let text = String(data: line, encoding: .utf8), !text.trimmingCharacters(in: .whitespaces).isEmpty {
                OverlayLog.write("skip non-json: \(text.prefix(200))")
            }
            return
        }

        if let method = object.string("method") {
            if method == "session/update" {
                if let params = object.dictionary("params") {
                    let update = params.dictionary("update") ?? params
                    let sid = params.string("sessionId") ?? sessionId ?? ""
                    if sid == sessionId, update.string("sessionUpdate") == "config_option_update" {
                        ingestConfigOptions(update.array("configOptions") ?? [])
                        notifyConfigChange()
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: params) {
                        onUpdate?(AcpUpdateDelivery(
                            sessionId: sid,
                            data: data,
                            receivedDuringReplay: isReplaying
                        ))
                    }
                }
                return
            }
            if method == "session/request_permission" {
                answerPermission(object)
                return
            }
            OverlayLog.write("ignored method \(method)")
        }

        guard let id = RPCID.parse(object["id"]) else { return }
        guard let continuation = pending.removeValue(forKey: id) else { return }
        inFlightPrompt = inFlightPrompt.filter { $0.value != id }
        if let error = object.dictionary("error") {
            let code = (error["code"] as? Int) ?? (error["code"] as? NSNumber)?.intValue ?? -1
            let message = error.string("message") ?? "agent error"
            continuation.resume(throwing: RPCError(code: code, message: message))
        } else {
            continuation.resume(returning: object["result"])
        }
    }

    private func answerPermission(_ message: [String: Any]) {
        guard let id = RPCID.parse(message["id"]) else { return }
        let params = message.dictionary("params") ?? [:]
        let options = params.array("options") ?? []
        let picked = pickAllowOption(options)
        let result: [String: Any]
        if let picked {
            result = [
                "outcome": [
                    "outcome": "selected",
                    "optionId": picked,
                ],
            ]
        } else {
            result = [
                "outcome": [
                    "outcome": "cancelled",
                ],
            ]
        }
        write([
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "result": result,
        ])
    }

    private func pickAllowOption(_ options: [Any]) -> String? {
        let parsed: [(String, String)] = options.compactMap { item in
            guard let object = JSONValue.object(item),
                  let id = object.string("optionId") else { return nil }
            return (id, object.string("kind") ?? "")
        }
        return parsed.first(where: { $0.1 == "allow_always" })?.0
            ?? parsed.first(where: { $0.1 == "allow_once" })?.0
            ?? parsed.first?.0
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        inFlightPrompt.removeAll()
        for (_, continuation) in waiting {
            continuation.resume(throwing: error)
        }
    }

    private func resetProcessLocked() {
        stdout?.readabilityHandler = nil
        stderr?.readabilityHandler = nil
        try? stdin?.close()
        stdin = nil
        stdout = nil
        stderr = nil
        process = nil
        sessionId = nil
        buffer.removeAll()
        inFlightPrompt.removeAll()
    }
}
