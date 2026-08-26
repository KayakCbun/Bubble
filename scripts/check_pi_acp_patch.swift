import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("pi-acp patch check failed: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum PiAcpPatchCheck {
static func main() throws {
let fixture = """
class PiRpcProcess {
  onEvent(handler) {
    return handler;
  }
  async getMessages() {
    const res = await this.request({ type: "get_messages" });
    return res.data;
  }
}
class PiAcpAgent {
  async restoreSession(sessionId, opts) {
    const existing = this.sessions.maybeGet(sessionId);
    if (existing) return existing;
  }
  constructor(conn, _config) {
    this.conn = conn;
  }
}
"""

let patched = try BubblePiAcpPatch.patch(source: fixture)
require(patched.contains("async getEntries()"), "get_entries bridge is injected")
require(patched.contains("async getTree()"), "get_tree bridge is injected")
require(patched.contains("async extMethod(method, params)"), "ACP extension dispatcher is injected")
require(patched.contains("_bubble/session/navigate_tree"), "navigation method is installed")
require(patched.contains("/bubble-navigate"), "navigation stays owned by the Pi extension")
require(patched.contains("_bubble/session/select_leaf"), "exact leaf selection method is installed")
require(patched.contains("async selectLeaf(targetId)"), "exact leaf selection reaches Pi RPC")
require(patched.contains("_bubble/session/recover_dead_rpc"), "dead Pi RPC recovery is marked")
require(patched.contains("isAlive()"), "Pi RPC liveness is observable")
require(patched.contains("existing?.proc?.isAlive?.()"), "live sessions are reused")
require(patched.contains("this.sessions.close(sessionId)"), "dead sessions are evicted before restore")
let patchedAgain = try BubblePiAcpPatch.patch(source: patched)
require(patchedAgain == patched, "patch is idempotent")

let legacyPatched = patched
    .replacingOccurrences(of: " && method !== \"_bubble/session/select_leaf\"", with: "")
    .replacingOccurrences(of: #"""
    if (method === "_bubble/session/select_leaf") {
      const targetId = typeof params.targetId === "string" ? params.targetId : "";
      if (!targetId) throw RequestError3.invalidParams("targetId is required");
      await session.proc.selectLeaf(targetId);
    }
"""#, with: "")
    .replacingOccurrences(of: #"""
  async selectLeaf(targetId) {
    const res = await this.request({ type: "bubble_select_leaf", targetId });
    if (!res.success) throw new Error(`pi select leaf failed: ${res.error ?? JSON.stringify(res.data)}`);
    return res.data;
  }

"""#, with: "")
let migratedLegacy = try BubblePiAcpPatch.patch(source: legacyPatched)
require(migratedLegacy.contains("_bubble/session/select_leaf"), "legacy Bubble ACP patch is upgraded in place")
require(migratedLegacy.contains("async selectLeaf(targetId)"), "legacy bridge gains exact leaf selection")

do {
    _ = try BubblePiAcpPatch.patch(source: "unexpected adapter")
    require(false, "unknown adapter source must be rejected")
} catch BubblePiAcpPatch.Error.unsupportedSource {
    // expected
}

let rpcFixture = """
switch (command.type) {
            case "get_tree": {
                return success(id, "get_tree", {});
            }
}
"""
let patchedRPC = try BubblePiRuntimePatch.patch(source: rpcFixture)
require(patchedRPC.contains("case \"bubble_select_leaf\""), "Pi RPC exact leaf command is installed")
require(patchedRPC.contains("session.bubbleSelectLeaf(targetId)"), "Pi RPC delegates exact selection to the session lifecycle")
let repatchedRPC = try BubblePiRuntimePatch.patch(source: patchedRPC)
require(repatchedRPC == patchedRPC, "Pi runtime patch is idempotent")
let legacyRPC = patchedRPC.replacingOccurrences(of: "const result = await session.bubbleSelectLeaf(targetId);", with: "session.sessionManager.branch(targetId);")
let migratedRPC = try BubblePiRuntimePatch.patch(source: legacyRPC)
require(migratedRPC.contains("session.bubbleSelectLeaf(targetId)"), "legacy direct runtime selection is upgraded")

let agentFixture = """
class AgentSession {
    async navigateTree(targetId, options = {}) {
        return { cancelled: false };
    }
}
"""
let patchedAgent = try BubblePiRuntimePatch.patchAgentSession(source: agentFixture)
require(patchedAgent.contains("async bubbleSelectLeaf(targetId)"), "exact leaf selection is installed on AgentSession")
require(patchedAgent.contains("session_before_tree"), "extensions can cancel exact leaf selection")
require(patchedAgent.contains("session_tree"), "extensions are notified after exact leaf selection")
require(patchedAgent.contains("this.sessionManager.branch(targetId)"), "exact selection keeps the target user entry in context")
let repatchedAgent = try BubblePiRuntimePatch.patchAgentSession(source: patchedAgent)
require(repatchedAgent == patchedAgent, "AgentSession patch is idempotent")

if let runtimePath = ProcessInfo.processInfo.environment["BUBBLE_PATCH_RUNTIME"] {
    let runtime = URL(fileURLWithPath: runtimePath, isDirectory: true)
    try BubblePiAcpPatch.apply(runtime: runtime)
    require(BubblePiAcpPatch.isApplied(runtime: runtime), "installed adapter is patched")
    try BubblePiRuntimePatch.apply(runtime: runtime)
    require(BubblePiRuntimePatch.isApplied(runtime: runtime), "installed Pi runtime is patched")
}

print("pi-acp patch checks passed")
}
}
