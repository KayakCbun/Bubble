import Foundation

public enum WorkspaceStatus: String, Codable, Equatable, Sendable {
    case running
    case waiting
    case done
    case failed
    case interrupted
}

public struct WorkspaceBrief: Codable, Equatable, Sendable {
    public var runId: String?
    public var path: String
    public var name: String
    public var status: WorkspaceStatus
    public var goal: String
    public var summary: String
    public var question: String?
    public var changedPaths: [String]

    public init(
        runId: String? = nil,
        path: String,
        name: String,
        status: WorkspaceStatus,
        goal: String,
        summary: String = "",
        question: String? = nil,
        changedPaths: [String] = []
    ) {
        self.runId = runId
        self.path = path
        self.name = name
        self.status = status
        self.goal = goal
        self.summary = summary
        self.question = question
        self.changedPaths = Array(changedPaths.prefix(WorkspaceRegistry.maxChangedPaths))
    }

    public var isActive: Bool {
        status == .running || status == .waiting
    }
}

public struct WorkspaceRelayRecord: Equatable, Sendable {
    public var brief: WorkspaceBrief
    public var sessionId: String?
    public var anchorEntryId: String?

    public init(brief: WorkspaceBrief, sessionId: String? = nil, anchorEntryId: String? = nil) {
        self.brief = brief
        self.sessionId = sessionId
        self.anchorEntryId = anchorEntryId
    }
}

private struct WorkspaceRelayPayloadV1: Codable {
    var brief: WorkspaceBrief
    var sessionId: String?
    var anchorEntryId: String?
}

public struct WorkspaceMount: Codable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var sessionId: String?

    public init(path: String, name: String, sessionId: String? = nil) {
        self.path = path
        self.name = name
        self.sessionId = sessionId
    }
}

public struct WorkspaceStoreFile: Codable, Equatable, Sendable {
    public var mounts: [WorkspaceMount]
    public var recent: [WorkspaceMount]
    public var active: WorkspaceBrief?

    public init(
        mounts: [WorkspaceMount] = [],
        recent: [WorkspaceMount] = [],
        active: WorkspaceBrief? = nil
    ) {
        self.mounts = mounts
        self.recent = recent
        self.active = active
    }
}

public enum WorkspacePaletteState: String, Equatable, Sendable {
    case unmounted
    case mounted
    case running
    case waiting
}

public struct WorkspacePaletteRow: Equatable, Sendable {
    public var path: String
    public var name: String
    public var subtitle: String
    public var state: WorkspacePaletteState
    public var role: String
    public var isBrowse: Bool { role == "browse" }

    public init(
        path: String,
        name: String,
        subtitle: String,
        state: WorkspacePaletteState,
        role: String = "enter"
    ) {
        self.path = path
        self.name = name
        self.subtitle = subtitle
        self.state = state
        self.role = role
    }
}

public enum WorkspacePromptEnvelope {
    private static let openingMarker = "<bubble-workspace>"
    private static let closingMarker = "</bubble-workspace>"

    public static func wrap(userText: String, workspaceStatus: String) -> String {
        """
        \(userText)

        \(openingMarker)
        \(workspaceStatus)
        \(closingMarker)
        """
    }

    public static func displayText(from raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(openingMarker),
           let closing = text.range(of: closingMarker) {
            return text[closing.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trailingMarker = "\n\n\(openingMarker)"
        if text.hasSuffix(closingMarker),
           let opening = text.range(of: trailingMarker, options: .backwards) {
            return text[..<opening.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}

public enum WorkspaceRegistry {
    public static let maxRecent = 12
    public static let maxChangedPaths = 20
    public static let maxSummaryChars = 800
    public static let browseSentinel = "__browse__"
    public static let parentSentinel = "__parent__"

    public static func load(from url: URL) -> WorkspaceStoreFile {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(WorkspaceStoreFile.self, from: data) else {
            return WorkspaceStoreFile()
        }
        return store
    }

    public static func save(_ store: WorkspaceStoreFile, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(store)
        try data.write(to: url, options: .atomic)
    }

    public static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    public static func expandPath(_ raw: String, home: URL) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" { return home.standardizedFileURL.path }
        if trimmed.hasPrefix("~/") {
            return home.appendingPathComponent(String(trimmed.dropFirst(2))).standardizedFileURL.path
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
        return home.appendingPathComponent(trimmed).standardizedFileURL.path
    }

    public static func displayName(path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    public static func displayPath(_ path: String, home: String) -> String {
        let normalized = normalize(path)
        let homePath = normalize(home)
        if normalized == homePath { return "~" }
        if normalized.hasPrefix(homePath + "/") {
            return "~/" + String(normalized.dropFirst(homePath.count + 1))
        }
        return normalized
    }

    public static func isProtected(_ path: String, bubbleRoot: String, workspace: String) -> Bool {
        let candidate = normalize(path)
        let root = normalize(bubbleRoot)
        let work = normalize(workspace)
        return candidate == root || candidate == work || candidate.hasPrefix(root + "/")
    }

    public static func mount(path: String, in store: inout WorkspaceStoreFile, bubbleRoot: String, workspace: String) throws {
        let normalized = normalize(path)
        if isProtected(normalized, bubbleRoot: bubbleRoot, workspace: workspace) {
            throw WorkspaceError.protectedPath
        }
        if store.mounts.contains(where: { $0.path == normalized }) {
            return
        }
        let entry = WorkspaceMount(path: normalized, name: displayName(path: normalized))
        store.mounts.insert(entry, at: 0)
        store.recent.removeAll { $0.path == normalized }
    }

    public static func unmount(path: String, in store: inout WorkspaceStoreFile) throws {
        let normalized = normalize(path)
        if let active = store.active, active.isActive, active.path == normalized {
            throw WorkspaceError.running
        }
        guard let index = store.mounts.firstIndex(where: { $0.path == normalized }) else {
            return
        }
        let removed = store.mounts.remove(at: index)
        store.recent.removeAll { $0.path == normalized }
        store.recent.insert(removed, at: 0)
        if store.recent.count > maxRecent {
            store.recent = Array(store.recent.prefix(maxRecent))
        }
        if store.active?.path == normalized, store.active?.isActive != true {
            store.active = nil
        }
    }

    public static func toggle(path: String, in store: inout WorkspaceStoreFile, bubbleRoot: String, workspace: String) throws -> String {
        let normalized = normalize(path)
        if store.mounts.contains(where: { $0.path == normalized }) {
            try unmount(path: normalized, in: &store)
            return "unmounted"
        }
        try mount(path: normalized, in: &store, bubbleRoot: bubbleRoot, workspace: workspace)
        return "mounted"
    }

    public static func rememberSession(path: String, sessionId: String, in store: inout WorkspaceStoreFile) {
        let normalized = normalize(path)
        if let index = store.mounts.firstIndex(where: { $0.path == normalized }) {
            store.mounts[index].sessionId = sessionId
        }
    }

    public static func sessionId(forMountPath path: String?, in store: WorkspaceStoreFile) -> String? {
        guard let path else { return nil }
        let normalized = normalize(path)
        return store.mounts.first(where: { $0.path == normalized })?.sessionId
    }

    public static func resetSessions(in store: inout WorkspaceStoreFile) {
        for index in store.mounts.indices {
            store.mounts[index].sessionId = nil
        }
        for index in store.recent.indices {
            store.recent[index].sessionId = nil
        }
    }

    public static func resolve(_ query: String, in store: WorkspaceStoreFile, home: URL) -> WorkspaceMount? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let exact = store.mounts.first(where: { $0.path == normalize(trimmed) }) {
            return exact
        }
        let expanded = expandPath(trimmed, home: home)
        if let byPath = store.mounts.first(where: { $0.path == expanded }) {
            return byPath
        }
        let lowered = trimmed.lowercased()
        let named = store.mounts.filter { $0.name.lowercased() == lowered }
        if named.count == 1 { return named[0] }
        return nil
    }

    public static func interruptActive(in store: inout WorkspaceStoreFile) {
        guard var active = store.active, active.isActive else { return }
        active.status = .interrupted
        if active.summary.isEmpty {
            active.summary = "Interrupted when Bubble quit."
        }
        store.active = active
    }

    public static func isPathQuery(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("~") || trimmed.hasPrefix("/") || trimmed.contains("/")
    }

    public static func enterQuery(path: String, home: URL) -> String {
        displayPath(normalize(path), home: home.path) + "/"
    }

    public static func parentQuery(query: String, home: URL, fileManager: FileManager = .default) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard isPathQuery(trimmed) else { return "" }
        guard let listing = listingDirectory(query: trimmed, home: home, fileManager: fileManager) else {
            return ""
        }
        let homePath = home.standardizedFileURL.path
        let parent = listing.deletingLastPathComponent().standardizedFileURL
        if listing.path == homePath || parent.path == homePath {
            return ""
        }
        if parent.path == "/" {
            return "/"
        }
        return displayPath(parent.path, home: home.path) + "/"
    }

    public static func listingDirectory(
        query: String,
        home: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard isPathQuery(trimmed) else { return nil }
        let expanded: URL
        if trimmed == "~" || trimmed == "~/" {
            expanded = home
        } else if trimmed.hasPrefix("~/") {
            expanded = home.appendingPathComponent(String(trimmed.dropFirst(2)))
        } else {
            expanded = URL(fileURLWithPath: trimmed)
        }
        if trimmed.hasSuffix("/") || trimmed == "~" {
            return expanded.standardizedFileURL
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: expanded.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return expanded.standardizedFileURL
        }
        return expanded.deletingLastPathComponent().standardizedFileURL
    }

    public static func paletteRows(
        store: WorkspaceStoreFile,
        query: String,
        home: URL,
        bubbleRoot: URL,
        workspace: URL,
        fileManager: FileManager = .default
    ) -> [WorkspacePaletteRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [WorkspacePaletteRow] = []
        var seen = Set<String>()
        let runningPath = store.active?.isActive == true ? store.active?.path : nil

        func state(for path: String) -> WorkspacePaletteState {
            let normalized = normalize(path)
            if runningPath == normalized {
                return store.active?.status == .waiting ? .waiting : .running
            }
            if store.mounts.contains(where: { $0.path == normalized }) {
                return .mounted
            }
            return .unmounted
        }

        func appendFolder(path: String, role: String, name: String? = nil, subtitle: String? = nil) {
            let normalized = normalize(path)
            guard seen.insert(normalized).inserted else { return }
            if isProtected(normalized, bubbleRoot: bubbleRoot.path, workspace: workspace.path) {
                return
            }
            let parent = URL(fileURLWithPath: normalized).deletingLastPathComponent().path
            rows.append(
                WorkspacePaletteRow(
                    path: normalized,
                    name: name ?? displayName(path: normalized),
                    subtitle: subtitle ?? displayPath(parent, home: home.path),
                    state: state(for: normalized),
                    role: role
                )
            )
        }

        if isPathQuery(trimmed), let listing = listingDirectory(query: trimmed, home: home, fileManager: fileManager) {
            let up = parentQuery(query: trimmed, home: home, fileManager: fileManager)
            rows.append(
                WorkspacePaletteRow(
                    path: up.isEmpty ? parentSentinel : expandPath(up, home: home),
                    name: "..",
                    subtitle: up.isEmpty ? "Workspaces" : displayPath(expandPath(up, home: home), home: home.path),
                    state: .unmounted,
                    role: "up"
                )
            )
            if trimmed.hasSuffix("/") || trimmed == "~" {
                appendFolder(path: listing.path, role: "toggle", subtitle: "This folder")
            }
            for path in directoryCompletions(query: trimmed, home: home, fileManager: fileManager) {
                appendFolder(path: path, role: "enter")
            }
            rows.append(
                WorkspacePaletteRow(
                    path: browseSentinel,
                    name: "Browse…",
                    subtitle: "Choose a folder",
                    state: .unmounted,
                    role: "browse"
                )
            )
            return rows
        }

        for mount in store.mounts {
            appendFolder(path: mount.path, role: "enter")
        }
        for recent in store.recent {
            appendFolder(path: recent.path, role: "enter")
        }
        for path in homeDirectories(home: home, bubbleRoot: bubbleRoot, workspace: workspace, fileManager: fileManager) {
            appendFolder(path: path, role: "enter")
        }

        if !trimmed.isEmpty {
            let q = trimmed.lowercased()
            rows = rows.filter { row in
                row.name.lowercased().contains(q)
                    || row.path.lowercased().contains(q)
                    || row.subtitle.lowercased().contains(q)
            }
        }

        rows.append(
            WorkspacePaletteRow(
                path: browseSentinel,
                name: "Browse…",
                subtitle: "Choose a folder",
                state: .unmounted,
                role: "browse"
            )
        )
        return rows
    }

    public static func statusBlock(
        _ store: WorkspaceStoreFile,
        home: String,
        skillsByMount: [String: [String]] = [:]
    ) -> String {
        var lines: [String] = []
        if store.mounts.isEmpty {
            lines.append("mounts: (none)")
        } else {
            lines.append("Call workspace_run(mount, prompt) when the ask matches a mounted repo or its skills. Do not bash or cd into those paths from this session. Those skills are not in your tool list.")
            lines.append("mounts:")
            for mount in store.mounts {
                lines.append("- \(mount.name): \(displayPath(mount.path, home: home))")
                if let skills = skillsByMount[mount.path], !skills.isEmpty {
                    let shown = skills.prefix(24).joined(separator: ", ")
                    let extra = skills.count > 24 ? " +\(skills.count - 24)" : ""
                    lines.append("  skills: \(shown)\(extra)")
                }
            }
        }
        if let active = store.active {
            lines.append("active: \(active.name) [\(active.status.rawValue)]")
            if !active.goal.isEmpty {
                lines.append("goal: \(active.goal)")
            }
            if !active.summary.isEmpty {
                lines.append("summary: \(clip(active.summary, maxSummaryChars))")
            }
            if let question = active.question, !question.isEmpty {
                lines.append("question: \(question)")
            }
            if !active.changedPaths.isEmpty {
                lines.append("changed_paths: \(active.changedPaths.joined(separator: ", "))")
            }
        } else {
            lines.append("active: none")
        }
        return lines.joined(separator: "\n")
    }

    public static func wrapUserPrompt(
        _ text: String,
        store: WorkspaceStoreFile,
        home: String,
        skillsByMount: [String: [String]] = [:]
    ) -> String {
        WorkspacePromptEnvelope.wrap(
            userText: text,
            workspaceStatus: statusBlock(store, home: home, skillsByMount: skillsByMount)
        )
    }

    public static func injectionPrompt(
        _ brief: WorkspaceBrief,
        home: String,
        sessionId: String? = nil,
        anchorEntryId: String? = nil
    ) -> String {
        var lines = [
            "The workspace run already finished. Summarize the result for the user in your own voice, then stop.",
            "Do not call workspace_run, mount_workspace, bash, or any other tool.",
            "Do not greet. Do not repeat the goal. Do not paste this block verbatim.",
            "name: \(brief.name)",
            "path: \(displayPath(brief.path, home: home))",
            "status: \(brief.status.rawValue)",
            "goal: \(brief.goal)",
        ]
        let payload = WorkspaceRelayPayloadV1(
            brief: brief,
            sessionId: sessionId,
            anchorEntryId: anchorEntryId
        )
        if !brief.summary.isEmpty {
            lines.append("summary: \(clip(brief.summary, maxSummaryChars))")
        }
        if let question = brief.question, !question.isEmpty {
            lines.append("question: \(question)")
        }
        if !brief.changedPaths.isEmpty {
            lines.append("changed_paths: \(brief.changedPaths.prefix(maxChangedPaths).joined(separator: ", "))")
        }
        if let data = try? JSONEncoder().encode(payload) {
            lines.append("bubble_workspace_relay_v1: \(data.base64EncodedString())")
        }
        return lines.joined(separator: "\n")
    }

    public static func directResultText(_ finalResponse: String, fallback brief: WorkspaceBrief) -> String {
        let complete = finalResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        if !complete.isEmpty { return complete }
        return brief.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func parseInjectionPrompt(_ prompt: String, home: String) -> WorkspaceRelayRecord? {
        let signature = """
        The workspace run already finished. Summarize the result for the user in your own voice, then stop.
        Do not call workspace_run, mount_workspace, bash, or any other tool.
        Do not greet. Do not repeat the goal. Do not paste this block verbatim.
        """
        guard prompt.hasPrefix(signature + "\n") else { return nil }

        if let encoded = prompt.split(separator: "\n").first(where: {
            $0.hasPrefix("bubble_workspace_relay_v1: ")
        })?.dropFirst("bubble_workspace_relay_v1: ".count),
           let data = Data(base64Encoded: String(encoded)),
           let payload = try? JSONDecoder().decode(WorkspaceRelayPayloadV1.self, from: data) {
            return WorkspaceRelayRecord(
                brief: payload.brief,
                sessionId: payload.sessionId,
                anchorEntryId: payload.anchorEntryId
            )
        }

        let labels = ["name", "path", "status", "goal", "summary", "question", "changed_paths"]
        func value(_ label: String) -> String? {
            let marker = "\n\(label): "
            guard let start = prompt.range(of: marker) else { return nil }
            let valueStart = start.upperBound
            let end = labels
                .filter { $0 != label }
                .compactMap { next in
                    prompt.range(of: "\n\(next): ", range: valueStart..<prompt.endIndex)?.lowerBound
                }
                .min() ?? prompt.endIndex
            return String(prompt[valueStart..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let name = value("name"), !name.isEmpty,
              let shownPath = value("path"), !shownPath.isEmpty,
              let statusText = value("status"), let status = WorkspaceStatus(rawValue: statusText),
              let goal = value("goal") else { return nil }
        let changedPaths = value("changed_paths")?.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? []
        return WorkspaceRelayRecord(
            brief: WorkspaceBrief(
                path: expandPath(shownPath, home: URL(fileURLWithPath: home)),
                name: name,
                status: status,
                goal: goal,
                summary: value("summary") ?? "",
                question: value("question"),
                changedPaths: changedPaths
            )
        )
    }

    public static func canMatchLegacyRelay(
        cardRunId: String?,
        structuredRelayRunIds: Set<String>
    ) -> Bool {
        guard let cardRunId, !cardRunId.isEmpty else { return true }
        return !structuredRelayRunIds.contains(cardRunId)
    }

    public static func inferWaiting(from summary: String) -> String? {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lastLine = trimmed
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
            ?? trimmed
        let asks = lastLine.contains("?")
            || lastLine.contains("？")
            || lastLine.contains("要不要")
            || lastLine.lowercased().contains("should i")
        guard asks else { return nil }
        return clip(lastLine, 240)
    }

    public static func clip(_ text: String, _ maxChars: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxChars { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxChars - 1)
        return String(trimmed[..<end]).trimmingCharacters(in: .whitespaces) + "…"
    }

    public static func homeDirectories(
        home: URL,
        bubbleRoot: URL,
        workspace: URL,
        fileManager: FileManager
    ) -> [String] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: home.path) else { return [] }
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .compactMap { name -> String? in
                let url = home.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                    return nil
                }
                let path = url.standardizedFileURL.path
                if isProtected(path, bubbleRoot: bubbleRoot.path, workspace: workspace.path) {
                    return nil
                }
                return path
            }
    }

    public static func directoryCompletions(
        query: String,
        home: URL,
        fileManager: FileManager
    ) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let expanded: URL
        if trimmed == "~" {
            expanded = home
        } else if trimmed.hasPrefix("~/") {
            expanded = home.appendingPathComponent(String(trimmed.dropFirst(2)))
        } else {
            expanded = URL(fileURLWithPath: trimmed)
        }

        var isDirectory: ObjCBool = false
        let listing: URL
        let prefix: String
        if fileManager.fileExists(atPath: expanded.path, isDirectory: &isDirectory),
           isDirectory.boolValue,
           trimmed.hasSuffix("/") || trimmed == "~" {
            listing = expanded
            prefix = ""
        } else {
            listing = expanded.deletingLastPathComponent()
            prefix = expanded.lastPathComponent.lowercased()
        }

        guard let names = try? fileManager.contentsOfDirectory(atPath: listing.path) else {
            return []
        }
        return names
            .filter { !$0.hasPrefix(".") }
            .filter { prefix.isEmpty || $0.lowercased().hasPrefix(prefix) }
            .sorted()
            .compactMap { name -> String? in
                let url = listing.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                    return nil
                }
                return url.standardizedFileURL.path
            }
    }
}

public enum WorkspaceError: Error, LocalizedError, Equatable {
    case protectedPath
    case running
    case notMounted
    case otherRunning(String)
    case noActiveRun
    case controlUnavailable

    public var errorDescription: String? {
        switch self {
        case .protectedPath:
            return "Bubble's own folder cannot be mounted."
        case .running:
            return "Stop the workspace run before unmounting."
        case .notMounted:
            return "That folder is not mounted."
        case .otherRunning(let name):
            return "\(name) is already running. Ask the user to wait, cancel, or note the new work."
        case .noActiveRun:
            return "No workspace run is in progress."
        case .controlUnavailable:
            return "Bubble control is not running."
        }
    }
}
