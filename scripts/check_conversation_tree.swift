import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("conversation tree check failed: \(message)\n", stderr)
        exit(1)
    }
}

private func message(
    _ id: String,
    parent: String?,
    role: String,
    text: String,
    thinking: String? = nil,
    toolName: String? = nil,
    image: Bool = false
) -> [String: Any] {
    var content: [[String: Any]] = []
    if let thinking {
        content.append(["type": "thinking", "thinking": thinking])
    }
    if !text.isEmpty {
        content.append(["type": "text", "text": text])
    }
    if image {
        content.append(["type": "image", "data": "base64"])
    }
    var value: [String: Any] = [
        "type": "message",
        "id": id,
        "parentId": parent as Any,
        "message": [
            "role": role,
            "content": content,
        ],
    ]
    if let toolName {
        var body = value["message"] as! [String: Any]
        body["toolName"] = toolName
        body["toolCallId"] = "call-\(id)"
        value["message"] = body
    }
    return value
}

@main
private enum ConversationTreeCheck {
static func main() {
let wrappedFirst = """
<bubble-workspace>
mounts: none
active: none
</bubble-workspace>

First question
"""
let longPrompt = String(repeating: "full prompt content ", count: 40)

let rawEntries: [[String: Any]] = [
    ["type": "model_change", "id": "model", "parentId": NSNull()],
    message("u1", parent: "model", role: "user", text: wrappedFirst),
    message("a1", parent: "u1", role: "assistant", text: "First answer", thinking: "First thought"),
    message("u2a", parent: "a1", role: "user", text: longPrompt, image: true),
    message("a2a", parent: "u2a", role: "assistant", text: "Answer A"),
    message("u2b", parent: "a1", role: "user", text: "Approach B"),
    message("tool-b", parent: "u2b", role: "toolResult", text: "tool output", toolName: "read"),
    message("a2b", parent: "tool-b", role: "assistant", text: "Answer B"),
]

let response: [String: Any] = [
    "entries": [
        "entries": rawEntries,
        "leafId": "a2b",
    ],
]

guard let snapshot = ConversationTreeSnapshot(response: response) else {
    fputs("conversation tree check failed: response did not parse\n", stderr)
    exit(1)
}

require(snapshot.leafID == "a2b", "leaf id")
require(
    snapshot.activePath.map(\.id) == ["model", "u1", "a1", "u2b", "tool-b", "a2b"],
    "active path excludes the sibling branch"
)

let variants = snapshot.variants(around: "u2b")
require(variants.map(\.entryID) == ["u2a", "u2b"], "sibling variants are ordered")
require(variants.map(\.tipID) == ["a2a", "a2b"], "each variant resolves to its latest tip")
require(variants.map(\.isCurrent) == [false, true], "current variant follows the active leaf")
require(snapshot.tipID(for: "u2a") == "a2a", "off-path entries expose a navigable branch tip")
require(snapshot.depth(of: "u2a") == 1, "tree rows expose conversation depth")

let transcript = snapshot.transcript
require(transcript.map(\.kind) == [.user, .thought, .assistant, .user, .tool, .assistant], "active transcript projection")
require(transcript.first?.text == "First question", "Bubble workspace metadata is hidden")
require(transcript[1].text == "First thought", "assistant thinking is preserved")
require(transcript[4].toolName == "read", "historic tool identity is preserved")
require(transcript[4].text == "tool output", "historic tool output is preserved")
require(transcript.first?.branchable == true, "plain text user messages remain branchable")

let oldBranch = snapshot.selecting(leafID: "a2a")
require(oldBranch.activePath.map(\.id) == ["model", "u1", "a1", "u2a", "a2a"], "selecting an older leaf is deterministic")
require(oldBranch.variants(around: "u2a").map(\.isCurrent) == [true, false], "variant selection follows restored leaf")
require(
    snapshot.restoredLeafID(savedLeafID: "a1") == "a2b",
    "a stale saved cursor that became an ancestor advances to the physical leaf"
)
require(
    snapshot.restoredLeafID(savedLeafID: "a2a") == "a2a",
    "an explicitly selected sibling branch remains selected"
)
require(oldBranch.transcript.first(where: { $0.entryID == "u2a" })?.branchable == false, "structured user messages stay branch-protected")
let structuredAssistant = ConversationTreeSnapshot(entries: [
    ConversationEntry(
        id: "assistant-with-tool",
        parentID: nil,
        type: "message",
        role: "assistant",
        text: "Done",
        thinking: "",
        toolName: nil,
        toolCallID: nil,
        isError: false,
        hasStructuredContent: true,
        order: 0
    ),
], leafID: "assistant-with-tool")
require(structuredAssistant.transcript.first?.branchable == true, "assistant responses remain valid branch points after structured content")
require(oldBranch.entries.first(where: { $0.id == "u2a" })?.displayText == longPrompt.trimmingCharacters(in: .whitespaces), "branch editing keeps the complete authoritative prompt")
require(!ConversationBranchRecovery.promptWasPersisted(in: oldBranch, after: "u2a"), "navigation alone is not a persisted branch prompt")
require(ConversationBranchRecovery.promptWasPersisted(in: snapshot, after: "a1"), "a later active user proves prompt acceptance")
require(
    !ConversationBranchRecovery.promptWasPersisted(in: snapshot, after: "a1", navigationSucceeded: false),
    "an unchanged old path cannot prove prompt acceptance when navigation failed"
)

let attachmentOnlyResponse: [String: Any] = [
    "entries": [
        "entries": [
            message("attachment", parent: nil, role: "user", text: "", image: true),
        ],
        "leafId": "attachment",
    ],
]
let attachmentOnly = ConversationTreeSnapshot(response: attachmentOnlyResponse)
require(attachmentOnly?.transcript.first?.text == "Attachment", "image-only user entries remain visible")
require(attachmentOnly?.transcript.first?.branchable == false, "image-only entries cannot be edited as text branches")

let jsonl = rawEntries.map { entry -> String in
    let data = try! JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}.joined(separator: "\n")
guard let localSnapshot = ConversationTreeSnapshot(jsonl: jsonl) else {
    fputs("conversation tree check failed: local JSONL did not parse\n", stderr)
    exit(1)
}
require(localSnapshot.leafID == "a2b", "local JSONL selects its latest active leaf")
require(localSnapshot.activePath.map(\.id) == snapshot.activePath.map(\.id), "local JSONL reconstructs the active path")
require(localSnapshot.transcript == snapshot.transcript, "local JSONL reconstructs the complete transcript")
let locallySelectedBranch = ConversationTreeSnapshot(jsonl: jsonl, selectedLeafID: "a2a")
require(locallySelectedBranch?.leafID == "a2a", "persisted local leaf selection overrides the physical tail")
require(locallySelectedBranch?.activePath.map(\.id) == oldBranch.activePath.map(\.id), "local selected leaf reconstructs its branch")

let relayText = """
The workspace run already finished. Summarize the result for the user in your own voice, then stop.
Do not call workspace_run, mount_workspace, bash, or any other tool.
Do not greet. Do not repeat the goal. Do not paste this block verbatim.
name: work
path: ~/Documents/work
status: done
goal: inspect the failed calls
summary: found the root cause
"""
let relaySnapshot = ConversationTreeSnapshot(entries: [
    ConversationEntry(id: "dispatch", parentID: nil, type: "message", role: "assistant", text: "I sent it.", thinking: "", toolName: nil, toolCallID: nil, isError: false, hasStructuredContent: false, order: 0),
    ConversationEntry(id: "relay", parentID: "dispatch", type: "message", role: "user", text: relayText, thinking: "", toolName: nil, toolCallID: nil, isError: false, hasStructuredContent: false, order: 1),
    ConversationEntry(id: "answer", parentID: "relay", type: "message", role: "assistant", text: "Here is the result.", thinking: "", toolName: nil, toolCallID: nil, isError: false, hasStructuredContent: false, order: 2),
], leafID: "answer")
require(
    relaySnapshot.transcript.map(\.kind) == [.assistant, .workspaceRelay, .assistant],
    "internal workspace relay prompts project as run-card anchors instead of user messages"
)
require(ConversationBranchInteraction.canSend(isSwitchingBranch: false), "composer sends when the active path is stable")
require(!ConversationBranchInteraction.canSend(isSwitchingBranch: true), "composer cannot race an in-flight branch switch")

print("conversation tree checks passed")
}
}
