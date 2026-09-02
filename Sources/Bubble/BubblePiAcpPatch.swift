import Foundation

enum BubblePiAcpPatch {
    static let packageVersion = "0.0.33"
    static let packageSpec = "pi-acp@\(packageVersion)"
    static let marker = "_bubble/session/select_leaf"
    static let workspaceResultMarker = "_bubble/session/append_workspace_result"
    static let recordNotesMarker = "_bubble/session/append_record_notes"
    static let recoveryMarker = "_bubble/session/recover_dead_rpc"
    static let customImageMarker = "_bubble/forward_custom_images"

    enum Error: Swift.Error, Equatable {
        case unsupportedSource
        case unsupportedVersion(String?)
        case missingAdapter
    }

    static func patch(source: String) throws -> String {
        var source = source
        let branchPatchApplied = source.contains(marker)
            && source.contains(workspaceResultMarker)
            && source.contains("async getEntries()")
            && source.contains("async getTree()")
            && source.contains("async selectLeaf(targetId)")
            && source.contains("async appendWorkspaceResult(text, details)")

        if !branchPatchApplied {
            if source.contains("_bubble/session/navigate_tree") {
                source = try removeLegacyPatch(from: source)
            }

            let processAnchor = "  async getMessages() {"
            let agentAnchor = "  constructor(conn, _config) {"
            guard source.range(of: processAnchor) != nil,
                  let agentRange = source.range(of: agentAnchor) else {
                throw Error.unsupportedSource
            }

        let processBridge = #"""
  async getEntries() {
    const res = await this.request({ type: "get_entries" });
    if (!res.success) throw new Error(`pi get_entries failed: ${res.error ?? JSON.stringify(res.data)}`);
    return res.data;
  }
  async getTree() {
    const res = await this.request({ type: "get_tree" });
    if (!res.success) throw new Error(`pi get_tree failed: ${res.error ?? JSON.stringify(res.data)}`);
    return res.data;
  }
  async selectLeaf(targetId) {
    const res = await this.request({ type: "bubble_select_leaf", targetId });
    if (!res.success) throw new Error(`pi select leaf failed: ${res.error ?? JSON.stringify(res.data)}`);
    return res.data;
  }
  async appendWorkspaceResult(text, details) {
    const res = await this.request({ type: "bubble_append_workspace_result", text, details });
    if (!res.success) throw new Error(`pi append workspace result failed: ${res.error ?? JSON.stringify(res.data)}`);
    return res.data;
  }
  async appendRecordNotes(text, details) {
    const res = await this.request({ type: "bubble_append_record_notes", text, details });
    if (!res.success) throw new Error(`pi append record notes failed: ${res.error ?? JSON.stringify(res.data)}`);
    return res.data;
  }

"""#

        let extensionBridge = #"""
  async extMethod(method, params) {
    if (method !== "_bubble/session/tree" && method !== "_bubble/session/navigate_tree" && method !== "_bubble/session/select_leaf" && method !== "_bubble/session/append_workspace_result" && method !== "_bubble/session/append_record_notes") {
      throw RequestError3.methodNotFound(method);
    }
    const sessionId = typeof params.sessionId === "string" ? params.sessionId : "";
    if (!sessionId) throw RequestError3.invalidParams("sessionId is required");
    const session = await this.restoreSession(sessionId);
    if (method === "_bubble/session/navigate_tree") {
      const targetId = typeof params.targetId === "string" ? params.targetId : "";
      if (!targetId) throw RequestError3.invalidParams("targetId is required");
      await session.proc.prompt(`/bubble-navigate ${targetId}`);
    }
    if (method === "_bubble/session/select_leaf") {
      const targetId = typeof params.targetId === "string" ? params.targetId : "";
      if (!targetId) throw RequestError3.invalidParams("targetId is required");
      await session.proc.selectLeaf(targetId);
    }
    if (method === "_bubble/session/append_workspace_result") {
      const text = typeof params.text === "string" ? params.text : "";
      if (!text.trim()) throw RequestError3.invalidParams("text is required");
      const details = params.details && typeof params.details === "object" ? params.details : undefined;
      await session.proc.appendWorkspaceResult(text, details);
    }
    if (method === "_bubble/session/append_record_notes") {
      const text = typeof params.text === "string" ? params.text : "";
      if (!text.trim()) throw RequestError3.invalidParams("text is required");
      const details = params.details && typeof params.details === "object" ? params.details : undefined;
      await session.proc.appendRecordNotes(text, details);
    }
    const [entries, tree] = await Promise.all([session.proc.getEntries(), session.proc.getTree()]);
    return { entries, tree };
  }
"""#

            var patched = source.replacingOccurrences(
                of: processAnchor,
                with: processBridge + "\n" + processAnchor,
                options: [],
                range: source.startIndex..<source.endIndex
            )
            guard let patchedAgentRange = patched.range(of: agentAnchor, range: agentRange.lowerBound..<patched.endIndex) else {
                throw Error.unsupportedSource
            }
            patched.insert(contentsOf: extensionBridge + "\n", at: patchedAgentRange.lowerBound)
            source = patched
        }

        let withRecordNotes = try patchRecordNotes(source: source)
        let recovered = try patchDeadSessionRecovery(source: withRecordNotes)
        return try patchCustomMessageImages(source: recovered)
    }

    private static func patchRecordNotes(source: String) throws -> String {
        var source = source
        if !source.contains("async appendRecordNotes(text, details)") {
            let anchor = "  async appendWorkspaceResult(text, details) {"
            guard source.contains(anchor) else { throw Error.unsupportedSource }
            let bridge = #"""
  async appendRecordNotes(text, details) {
    const res = await this.request({ type: "bubble_append_record_notes", text, details });
    if (!res.success) throw new Error(`pi append record notes failed: ${res.error ?? JSON.stringify(res.data)}`);
    return res.data;
  }

"""#
            source = source.replacingOccurrences(of: anchor, with: bridge + anchor)
        }
        if !source.contains(#"method !== "_bubble/session/append_record_notes""#) {
            let allowlist = #"method !== "_bubble/session/append_workspace_result""#
            guard source.contains(allowlist) else { throw Error.unsupportedSource }
            source = source.replacingOccurrences(
                of: allowlist,
                with: allowlist + #" && method !== "_bubble/session/append_record_notes""#
            )
        }
        if !source.contains(#"method === "_bubble/session/append_record_notes""#) {
            let handler = #"""
    if (method === "_bubble/session/append_workspace_result") {
      const text = typeof params.text === "string" ? params.text : "";
      if (!text.trim()) throw RequestError3.invalidParams("text is required");
      const details = params.details && typeof params.details === "object" ? params.details : undefined;
      await session.proc.appendWorkspaceResult(text, details);
    }
"""#
            guard source.contains(handler) else { throw Error.unsupportedSource }
            let extra = #"""
    if (method === "_bubble/session/append_workspace_result") {
      const text = typeof params.text === "string" ? params.text : "";
      if (!text.trim()) throw RequestError3.invalidParams("text is required");
      const details = params.details && typeof params.details === "object" ? params.details : undefined;
      await session.proc.appendWorkspaceResult(text, details);
    }
    if (method === "_bubble/session/append_record_notes") {
      const text = typeof params.text === "string" ? params.text : "";
      if (!text.trim()) throw RequestError3.invalidParams("text is required");
      const details = params.details && typeof params.details === "object" ? params.details : undefined;
      await session.proc.appendRecordNotes(text, details);
    }
"""#
            source = source.replacingOccurrences(of: handler, with: extra)
        }
        return source
    }

    private static func patchCustomMessageImages(source: String) throws -> String {
        if source.contains(customImageMarker) { return source }
        let helperAnchor = "function normalizePiMessageText(content) {"
        let eventAnchor = #"      case "tool_execution_start": {"#
        let replayAnchor = #"      if (role === "toolResult") {"#
        guard source.contains(helperAnchor),
              source.contains(eventAnchor),
              source.contains(replayAnchor) else {
            throw Error.unsupportedSource
        }

        let helper = #"""
// _bubble/forward_custom_images
function bubbleDisplayContentBlocks(content) {
  const blocks = typeof content === "string"
    ? [{ type: "text", text: content }]
    : Array.isArray(content) ? content : [];
  return blocks.flatMap((block) => {
    if (block?.type === "text" && typeof block.text === "string" && block.text) {
      return [{ type: "text", text: block.text }];
    }
    if (block?.type === "image"
      && typeof block.mimeType === "string"
      && block.mimeType.startsWith("image/")
      && typeof block.data === "string"
      && block.data) {
      return [{ type: "image", mimeType: block.mimeType, data: block.data }];
    }
    return [];
  });
}

"""#
        let eventBridge = #"""
      case "message_end": {
        const message = ev.message;
        if (message?.role !== "custom" || message.display !== true) break;
        const blocks = bubbleDisplayContentBlocks(message.content);
        for (const [index, content] of blocks.entries()) {
          this.emit({
            sessionUpdate: "agent_message_chunk",
            content,
            bubbleCustomMessageStart: index === 0,
            bubbleCustomMessageEnd: index === blocks.length - 1
          });
        }
        break;
      }
"""#
        let replayBridge = #"""
      if (role === "custom" && m?.display === true) {
        const blocks = bubbleDisplayContentBlocks(m?.content);
        for (const [index, content] of blocks.entries()) {
          await this.conn.sessionUpdate({
            sessionId: session.sessionId,
            update: {
              sessionUpdate: "agent_message_chunk",
              content,
              bubbleCustomMessageStart: index === 0,
              bubbleCustomMessageEnd: index === blocks.length - 1
            }
          });
        }
      }
"""#
        return source
            .replacingOccurrences(of: helperAnchor, with: helper + helperAnchor, options: [], range: source.startIndex..<source.endIndex)
            .replacingOccurrences(of: eventAnchor, with: eventBridge + eventAnchor, options: [], range: source.startIndex..<source.endIndex)
            .replacingOccurrences(of: replayAnchor, with: replayBridge + replayAnchor, options: [], range: source.startIndex..<source.endIndex)
    }

    private static func patchDeadSessionRecovery(source: String) throws -> String {
        if source.contains(recoveryMarker),
           source.contains("existing?.proc?.isAlive?.()"),
           source.contains("this.sessions.close(sessionId)") {
            return source
        }

        let processAnchor = "  onEvent(handler) {"
        let restoreAnchor = #"""
    const existing = this.sessions.maybeGet(sessionId);
    if (existing) return existing;
"""#
        guard source.contains(processAnchor), source.contains(restoreAnchor) else {
            throw Error.unsupportedSource
        }

        let livenessBridge = #"""
  // _bubble/session/recover_dead_rpc
  isAlive() {
    return this.child.exitCode === null
      && !this.child.killed
      && this.child.stdin?.destroyed !== true
      && this.child.stdin?.writableEnded !== true;
  }

"""#
        let restoreBridge = #"""
    const existing = this.sessions.maybeGet(sessionId);
    if (existing?.proc?.isAlive?.()) return existing;
    if (existing) this.sessions.close(sessionId);
"""#
        return source
            .replacingOccurrences(of: processAnchor, with: livenessBridge + processAnchor, options: [], range: source.startIndex..<source.endIndex)
            .replacingOccurrences(of: restoreAnchor, with: restoreBridge, options: [], range: source.startIndex..<source.endIndex)
    }

    private static func removeLegacyPatch(from source: String) throws -> String {
        let processStart = "  async getEntries() {"
        let processEnd = "  async getMessages() {"
        let extensionStart = "  async extMethod(method, params) {"
        let extensionEnd = "  constructor(conn, _config) {"
        guard let processRangeStart = source.range(of: processStart)?.lowerBound,
              let processRangeEnd = source.range(of: processEnd)?.lowerBound,
              processRangeStart < processRangeEnd else {
            throw Error.unsupportedSource
        }
        var clean = source
        clean.removeSubrange(processRangeStart..<processRangeEnd)
        guard let extensionRangeStart = clean.range(of: extensionStart)?.lowerBound,
              let extensionRangeEnd = clean.range(of: extensionEnd)?.lowerBound,
              extensionRangeStart < extensionRangeEnd else {
            throw Error.unsupportedSource
        }
        clean.removeSubrange(extensionRangeStart..<extensionRangeEnd)
        return clean
    }

    static func apply(runtime: URL) throws {
        let package = runtime.appendingPathComponent("node_modules/pi-acp/package.json")
        let adapter = runtime.appendingPathComponent("node_modules/pi-acp/dist/index.js")
        guard let packageData = try? Data(contentsOf: package),
              let manifest = try? JSONSerialization.jsonObject(with: packageData) as? [String: Any],
              let source = try? String(contentsOf: adapter, encoding: .utf8) else {
            throw Error.missingAdapter
        }
        let version = manifest["version"] as? String
        guard version == packageVersion else { throw Error.unsupportedVersion(version) }
        let patched = try patch(source: source)
        if patched != source {
            try patched.write(to: adapter, atomically: true, encoding: .utf8)
        }
    }

    static func isApplied(runtime: URL) -> Bool {
        let package = runtime.appendingPathComponent("node_modules/pi-acp/package.json")
        let adapter = runtime.appendingPathComponent("node_modules/pi-acp/dist/index.js")
        guard let packageData = try? Data(contentsOf: package),
              let manifest = try? JSONSerialization.jsonObject(with: packageData) as? [String: Any],
              manifest["version"] as? String == packageVersion,
              let source = try? String(contentsOf: adapter, encoding: .utf8) else { return false }
        return source.contains(marker)
            && source.contains("async getEntries()")
            && source.contains("async getTree()")
            && source.contains("async selectLeaf(targetId)")
            && source.contains(workspaceResultMarker)
            && source.contains("async appendWorkspaceResult(text, details)")
            && source.contains(recordNotesMarker)
            && source.contains("async appendRecordNotes(text, details)")
            && source.contains(recoveryMarker)
            && source.contains("existing?.proc?.isAlive?.()")
            && source.contains("this.sessions.close(sessionId)")
            && source.contains(customImageMarker)
            && source.contains("bubbleDisplayContentBlocks")
    }

    /// Re-patch an already-installed adapter when Bubble adds new ACP methods.
    /// Returns false only when the package is missing or the wrong version.
    @discardableResult
    static func ensureApplied(runtime: URL) -> Bool {
        do {
            try apply(runtime: runtime)
            return isApplied(runtime: runtime)
        } catch {
            return false
        }
    }
}

enum BubblePiRuntimePatch {
    static let packageVersion = "0.84.2"
    static let packageSpec = "@earendil-works/pi-coding-agent@\(packageVersion)"
    static let marker = "session.bubbleSelectLeaf(targetId)"
    static let agentMarker = "async bubbleSelectLeaf(targetId)"
    static let workspaceResultMarker = "session.bubbleAppendWorkspaceResult(text, details)"
    static let agentWorkspaceResultMarker = "async bubbleAppendWorkspaceResult(text, details)"
    static let recordNotesMarker = "session.bubbleAppendRecordNotes(text, details)"
    static let agentRecordNotesMarker = "async bubbleAppendRecordNotes(text, details)"

    enum Error: Swift.Error, Equatable {
        case unsupportedSource
        case unsupportedVersion(String?)
        case missingRuntime
    }

    static func patch(source: String) throws -> String {
        if source.contains(marker),
           source.contains(workspaceResultMarker),
           source.contains(recordNotesMarker) { return source }
        var source = source
        if source.contains(workspaceResultMarker), !source.contains(recordNotesMarker) {
            let workspaceCase = #"            case "bubble_append_workspace_result": {"#
            guard source.contains(workspaceCase) else { throw Error.unsupportedSource }
            let recordOnly = #"""
            case "bubble_append_record_notes": {
                const text = command.text;
                const details = command.details;
                if (typeof text !== "string" || !text.trim()) {
                    return error(id, "bubble_append_record_notes", "Record notes text is required");
                }
                const result = await session.bubbleAppendRecordNotes(text, details);
                return success(id, "bubble_append_record_notes", result);
            }

"""#
            return source.replacingOccurrences(of: workspaceCase, with: recordOnly + workspaceCase)
        }
        if let legacyStart = source.range(of: "            case \"bubble_select_leaf\": {")?.lowerBound,
           let anchorStart = source.range(of: #"            case "get_tree": {"#)?.lowerBound,
           legacyStart < anchorStart {
            source.removeSubrange(legacyStart..<anchorStart)
        }
        let anchor = #"            case "get_tree": {"#
        guard source.contains(anchor) else { throw Error.unsupportedSource }
        let bridge = #"""
            case "bubble_append_record_notes": {
                const text = command.text;
                const details = command.details;
                if (typeof text !== "string" || !text.trim()) {
                    return error(id, "bubble_append_record_notes", "Record notes text is required");
                }
                const result = await session.bubbleAppendRecordNotes(text, details);
                return success(id, "bubble_append_record_notes", result);
            }
            case "bubble_append_workspace_result": {
                const text = command.text;
                const details = command.details;
                if (typeof text !== "string" || !text.trim()) {
                    return error(id, "bubble_append_workspace_result", "Workspace result text is required");
                }
                const result = await session.bubbleAppendWorkspaceResult(text, details);
                return success(id, "bubble_append_workspace_result", result);
            }
            case "bubble_select_leaf": {
                const targetId = command.targetId;
                if (typeof targetId !== "string") {
                    return error(id, "bubble_select_leaf", `Entry not found: ${targetId}`);
                }
                const result = await session.bubbleSelectLeaf(targetId);
                if (result.cancelled) {
                    return error(id, "bubble_select_leaf", "Branch navigation was cancelled");
                }
                return success(id, "bubble_select_leaf", { leafId: session.sessionManager.getLeafId() });
            }
"""#
        return source.replacingOccurrences(of: anchor, with: bridge + "\n" + anchor)
    }

    static func patchAgentSession(source: String) throws -> String {
        if source.contains(agentMarker),
           source.contains(agentWorkspaceResultMarker),
           source.contains(agentRecordNotesMarker) { return source }
        if source.contains(agentWorkspaceResultMarker), !source.contains(agentRecordNotesMarker) {
            let workspaceMethod = "    async bubbleAppendWorkspaceResult(text, details) {"
            guard let range = source.range(of: workspaceMethod) else { throw Error.unsupportedSource }
            let recordMethod = #"""
    async bubbleAppendRecordNotes(text, details) {
        if (this.isStreaming) {
            throw new Error("Wait for the current response to finish before appending record notes.");
        }
        await this.sendCustomMessage({
            customType: "bubble_record_notes",
            content: [{ type: "text", text }],
            display: true,
            details,
        }, { triggerTurn: false });
        return { entryId: this.sessionManager.getLeafId() };
    }

"""#
            var migrated = source
            migrated.insert(contentsOf: recordMethod, at: range.lowerBound)
            return migrated
        }
        let anchor = "    async navigateTree(targetId, options = {}) {"
        guard source.contains(anchor) else { throw Error.unsupportedSource }
        var workspaceBridge = ""
        if !source.contains(agentWorkspaceResultMarker) {
            workspaceBridge = #"""
    async bubbleAppendWorkspaceResult(text, details) {
        if (this.isStreaming) {
            throw new Error("Wait for the current response to finish before appending a workspace result.");
        }
        await this.sendCustomMessage({
            customType: "bubble_workspace_result",
            content: [{ type: "text", text }],
            display: true,
            details,
        }, { triggerTurn: false });
        return { entryId: this.sessionManager.getLeafId() };
    }
    async bubbleAppendRecordNotes(text, details) {
        if (this.isStreaming) {
            throw new Error("Wait for the current response to finish before appending record notes.");
        }
        await this.sendCustomMessage({
            customType: "bubble_record_notes",
            content: [{ type: "text", text }],
            display: true,
            details,
        }, { triggerTurn: false });
        return { entryId: this.sessionManager.getLeafId() };
    }

"""#
        }
        var selectionBridge = ""
        if !source.contains(agentMarker) {
            selectionBridge = #"""
    async bubbleSelectLeaf(targetId) {
        if (this.isStreaming) {
            throw new Error("Wait for the current response to finish before navigating the session tree.");
        }
        const oldLeafId = this.sessionManager.getLeafId();
        if (targetId === oldLeafId) return { cancelled: false };
        const targetEntry = this.sessionManager.getEntry(targetId);
        if (!targetEntry) throw new Error(`Entry ${targetId} not found`);
        const { entries: entriesToSummarize, commonAncestorId } = collectEntriesForBranchSummary(this.sessionManager, oldLeafId, targetId);
        const preparation = {
            targetId,
            oldLeafId,
            commonAncestorId,
            entriesToSummarize,
            userWantsSummary: false,
            customInstructions: undefined,
            replaceInstructions: undefined,
            label: undefined,
        };
        this._branchSummaryAbortController = new AbortController();
        try {
            if (this._extensionRunner.hasHandlers("session_before_tree")) {
                const result = await this._extensionRunner.emit({
                    type: "session_before_tree",
                    preparation,
                    signal: this._branchSummaryAbortController.signal,
                });
                if (result?.cancel) return { cancelled: true };
            }
            this.sessionManager.branch(targetId);
            const sessionContext = this.sessionManager.buildSessionContext();
            this.agent.state.messages = sessionContext.messages;
            await this._extensionRunner.emit({
                type: "session_tree",
                newLeafId: this.sessionManager.getLeafId(),
                oldLeafId,
            });
            return { cancelled: false };
        }
        finally {
            this._branchSummaryAbortController = undefined;
        }
    }

"""#
        }
        return source.replacingOccurrences(of: anchor, with: workspaceBridge + selectionBridge + anchor)
    }

    static func apply(runtime: URL) throws {
        let base = runtime.appendingPathComponent("node_modules/@earendil-works/pi-coding-agent")
        let package = base.appendingPathComponent("package.json")
        let rpcMode = base.appendingPathComponent("dist/modes/rpc/rpc-mode.js")
        let agentSession = base.appendingPathComponent("dist/core/agent-session.js")
        guard let packageData = try? Data(contentsOf: package),
              let manifest = try? JSONSerialization.jsonObject(with: packageData) as? [String: Any],
              let source = try? String(contentsOf: rpcMode, encoding: .utf8),
              let agentSource = try? String(contentsOf: agentSession, encoding: .utf8) else {
            throw Error.missingRuntime
        }
        let version = manifest["version"] as? String
        guard version == packageVersion else { throw Error.unsupportedVersion(version) }
        let patched = try patch(source: source)
        let patchedAgent = try patchAgentSession(source: agentSource)
        if patched != source {
            try patched.write(to: rpcMode, atomically: true, encoding: .utf8)
        }
        if patchedAgent != agentSource {
            try patchedAgent.write(to: agentSession, atomically: true, encoding: .utf8)
        }
    }

    static func isApplied(runtime: URL) -> Bool {
        let base = runtime.appendingPathComponent("node_modules/@earendil-works/pi-coding-agent")
        let package = base.appendingPathComponent("package.json")
        let rpcMode = base.appendingPathComponent("dist/modes/rpc/rpc-mode.js")
        let agentSession = base.appendingPathComponent("dist/core/agent-session.js")
        guard let packageData = try? Data(contentsOf: package),
              let manifest = try? JSONSerialization.jsonObject(with: packageData) as? [String: Any],
              manifest["version"] as? String == packageVersion,
              let source = try? String(contentsOf: rpcMode, encoding: .utf8),
              let agentSource = try? String(contentsOf: agentSession, encoding: .utf8) else { return false }
        return source.contains(marker)
            && source.contains(workspaceResultMarker)
            && source.contains(recordNotesMarker)
            && agentSource.contains(agentMarker)
            && agentSource.contains(agentWorkspaceResultMarker)
            && agentSource.contains(agentRecordNotesMarker)
    }

    @discardableResult
    static func ensureApplied(runtime: URL) -> Bool {
        do {
            try apply(runtime: runtime)
            return isApplied(runtime: runtime)
        } catch {
            return false
        }
    }
}
