import Foundation

enum BubblePiAcpPatch {
    static let packageVersion = "0.0.33"
    static let packageSpec = "pi-acp@\(packageVersion)"
    static let marker = "_bubble/session/select_leaf"
    static let recoveryMarker = "_bubble/session/recover_dead_rpc"

    enum Error: Swift.Error, Equatable {
        case unsupportedSource
        case unsupportedVersion(String?)
        case missingAdapter
    }

    static func patch(source: String) throws -> String {
        var source = source
        let branchPatchApplied = source.contains(marker)
            && source.contains("async getEntries()")
            && source.contains("async getTree()")
            && source.contains("async selectLeaf(targetId)")

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

"""#

        let extensionBridge = #"""
  async extMethod(method, params) {
    if (method !== "_bubble/session/tree" && method !== "_bubble/session/navigate_tree" && method !== "_bubble/session/select_leaf") {
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

        return try patchDeadSessionRecovery(source: source)
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
            && source.contains(recoveryMarker)
            && source.contains("existing?.proc?.isAlive?.()")
            && source.contains("this.sessions.close(sessionId)")
    }
}

enum BubblePiRuntimePatch {
    static let packageVersion = "0.84.2"
    static let packageSpec = "@earendil-works/pi-coding-agent@\(packageVersion)"
    static let marker = "session.bubbleSelectLeaf(targetId)"
    static let agentMarker = "async bubbleSelectLeaf(targetId)"

    enum Error: Swift.Error, Equatable {
        case unsupportedSource
        case unsupportedVersion(String?)
        case missingRuntime
    }

    static func patch(source: String) throws -> String {
        if source.contains(marker) { return source }
        var source = source
        if let legacyStart = source.range(of: "            case \"bubble_select_leaf\": {")?.lowerBound,
           let anchorStart = source.range(of: #"            case "get_tree": {"#)?.lowerBound,
           legacyStart < anchorStart {
            source.removeSubrange(legacyStart..<anchorStart)
        }
        let anchor = #"            case "get_tree": {"#
        guard source.contains(anchor) else { throw Error.unsupportedSource }
        let bridge = #"""
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
        if source.contains(agentMarker) { return source }
        let anchor = "    async navigateTree(targetId, options = {}) {"
        guard source.contains(anchor) else { throw Error.unsupportedSource }
        let bridge = #"""
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
        return source.replacingOccurrences(of: anchor, with: bridge + anchor)
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
        return source.contains(marker) && agentSource.contains(agentMarker)
    }
}
