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
function normalizePiMessageText(content) {
  return String(content ?? "");
}
class PiRpcProcess {
  onEvent(handler) {
    return handler;
  }
  async getMessages() {
    const res = await this.request({ type: "get_messages" });
    return res.data;
  }
}
class PiAcpSession {
  handlePiEvent(ev) {
    switch (ev.type) {
      case "tool_execution_start": {
        break;
      }
    }
  }
}
class PiAcpAgent {
  async restoreSession(sessionId, opts) {
    const existing = this.sessions.maybeGet(sessionId);
    if (existing) return existing;
  }
  async replay(messages) {
    for (const m of messages) {
      const role = String(m?.role ?? "");
      if (role === "toolResult") {
        continue;
      }
    }
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
require(patched.contains("_bubble/session/append_workspace_result"), "workspace results have a direct ACP append method")
require(patched.contains("async appendWorkspaceResult(text, details)"), "workspace result append reaches Pi RPC")
require(patched.contains("_bubble/session/append_record_notes"), "record notes have a direct ACP append method")
require(patched.contains("async appendRecordNotes(text, details)"), "record notes append reaches Pi RPC")
require(patched.contains("_bubble/session/recover_dead_rpc"), "dead Pi RPC recovery is marked")
require(patched.contains("isAlive()"), "Pi RPC liveness is observable")
require(patched.contains("existing?.proc?.isAlive?.()"), "live sessions are reused")
require(patched.contains("this.sessions.close(sessionId)"), "dead sessions are evicted before restore")
require(patched.contains("_bubble/forward_custom_images"), "displayed Pi custom images are forwarded to ACP")
require(patched.contains("bubbleCustomMessageStart: index === 0"), "custom message boundaries survive live and replay forwarding")
require(patched.contains("bubbleCustomMessageEnd: index === blocks.length - 1"), "custom messages cannot merge into the following assistant row")
require(patched.contains("message?.role !== \"custom\""), "only Pi custom messages use the custom-image bridge")
require(patched.contains("sessionUpdate: \"agent_message_chunk\""), "custom image blocks become assistant content chunks")
require(
    patched.contains(#"message.customType === "bubble_record_notes""#),
    "live Record notes stay on the Record card instead of an assistant chunk"
)
require(
    patched.contains(#"m?.customType !== "bubble_record_notes""#),
    "replayed Record notes stay on the Record card instead of an assistant chunk"
)
let patchedAgain = try BubblePiAcpPatch.patch(source: patched)
require(patchedAgain == patched, "patch is idempotent")

let staleRecordAdapter = patched
    .replacingOccurrences(of: "async appendRecordNotes(text, details)", with: "async appendWorkspaceResult(text, details)")
    .replacingOccurrences(of: #" && method !== "_bubble/session/append_record_notes""#, with: "")
    .replacingOccurrences(
        of: #"""
    if (method === "_bubble/session/append_record_notes") {
      const text = typeof params.text === "string" ? params.text : "";
      if (!text.trim()) throw RequestError3.invalidParams("text is required");
      const details = params.details && typeof params.details === "object" ? params.details : undefined;
      await session.proc.appendRecordNotes(text, details);
    }
"""#,
        with: ""
    )
require(!staleRecordAdapter.contains("_bubble/session/append_record_notes")
        || staleRecordAdapter.contains("appendRecordNotes") == false,
        "stale adapter fixture dropped the Record notes method")
let upgradedRecordAdapter = try BubblePiAcpPatch.patch(source: staleRecordAdapter)
require(upgradedRecordAdapter.contains("async appendRecordNotes(text, details)"),
        "a previously patched adapter gains Record notes without reinstalling Pi")
require(upgradedRecordAdapter.contains("_bubble/session/append_record_notes"),
        "a previously patched adapter exposes the Record notes ACP method")

let staleRecordForwarding = patched
    .replacingOccurrences(
        of: #"if (message?.role !== "custom" || message.display !== true || message.customType === "bubble_record_notes") break;"#,
        with: #"if (message?.role !== "custom" || message.display !== true) break;"#
    )
    .replacingOccurrences(
        of: #"if (role === "custom" && m?.display === true && m?.customType !== "bubble_record_notes") {"#,
        with: #"if (role === "custom" && m?.display === true) {"#
    )
require(
    !staleRecordForwarding.contains(#"message.customType === "bubble_record_notes""#),
    "stale adapter fixture still forwarded Record notes as assistant chunks"
)
let upgradedRecordForwarding = try BubblePiAcpPatch.patch(source: staleRecordForwarding)
require(
    upgradedRecordForwarding.contains(#"message.customType === "bubble_record_notes""#),
    "a previously patched adapter stops forwarding live Record notes as assistant chunks"
)
require(
    upgradedRecordForwarding.contains(#"m?.customType !== "bubble_record_notes""#),
    "a previously patched adapter stops replaying Record notes as assistant chunks"
)

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
require(patchedRPC.contains("case \"bubble_append_workspace_result\""), "Pi RPC accepts direct workspace results")
require(patchedRPC.contains("session.bubbleAppendWorkspaceResult(text, details)"), "Pi RPC persists workspace results through AgentSession")
require(patchedRPC.contains("case \"bubble_append_record_notes\""), "Pi RPC accepts record notes")
require(patchedRPC.contains("session.bubbleAppendRecordNotes(text, details)"), "Pi RPC persists record notes through AgentSession")
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
require(patchedAgent.contains("async bubbleAppendWorkspaceResult(text, details)"), "AgentSession can append a workspace result")
require(patchedAgent.contains("customType: \"bubble_workspace_result\""), "workspace results use a recognizable context message type")
require(patchedAgent.contains("display: true"), "workspace results render as assistant replies")
require(patchedAgent.contains("triggerTurn: false"), "workspace result append does not invoke the main model again")
require(patchedAgent.contains("async bubbleAppendRecordNotes(text, details)"), "AgentSession can append record notes")
require(patchedAgent.contains("customType: \"bubble_record_notes\""), "record notes use a recognizable context message type")
require(
    patchedAgent.contains("""
            customType: "bubble_record_notes",
            content: [{ type: "text", text }],
            display: false,
"""),
    "record notes stay on the Record card instead of duplicating as an assistant message"
)
require(patchedAgent.contains("triggerTurn: false"), "record notes append does not invoke the main model again")
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
