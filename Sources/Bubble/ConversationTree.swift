#if canImport(BubbleMounts)
import BubbleMounts
#endif
import Foundation

struct ConversationEntry: Equatable, Sendable {
    var id: String
    var parentID: String?
    var type: String
    var role: String?
    var text: String
    var thinking: String
    var toolName: String?
    var toolCallID: String?
    var isError: Bool
    var hasStructuredContent: Bool
    var images: [AssistantMessageImage] = []
    var imageOffsets: [Int] = []
    var order: Int

    var isUserMessage: Bool { type == "message" && role == "user" }
    var displayText: String { ConversationTreeSnapshot.displayUserText(text) }
}

struct ConversationVariant: Equatable {
    var entryID: String
    var tipID: String
    var title: String
    var isCurrent: Bool
}

struct ConversationTranscriptRecord: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case user
        case assistant
        case thought
        case tool
        case workspaceRelay
    }

    var kind: Kind
    var entryID: String
    var text: String
    var toolName: String?
    var toolCallID: String?
    var isError: Bool
    var branchable: Bool
    var images: [AssistantMessageImage] = []
    var imageOffsets: [Int] = []
}

struct ConversationTreeSnapshot: Equatable, Sendable {
    var entries: [ConversationEntry]
    var leafID: String?

    init(entries: [ConversationEntry], leafID: String?) {
        self.entries = entries
        self.leafID = leafID
    }

    init?(response: Any?) {
        guard let root = response as? [String: Any] else { return nil }
        let envelope = root["entries"] as? [String: Any] ?? root
        guard let rawEntries = envelope["entries"] as? [Any] else { return nil }
        entries = rawEntries.enumerated().compactMap { index, raw in
            Self.parseEntry(raw, order: index)
        }
        leafID = Self.string(envelope["leafId"])
    }

    /// Reconstruct the tree directly from Pi's append-only local session. A
    /// separately persisted read-only selection wins when supplied; otherwise
    /// Pi reopens the session at its final physical entry.
    init?(jsonl: String, selectedLeafID: String? = nil) {
        let rawEntries: [[String: Any]] = jsonl
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        entries = rawEntries.enumerated().compactMap { index, raw in
            Self.parseEntry(raw, order: index)
        }
        guard let fallbackLeaf = entries.last?.id else { return nil }
        leafID = selectedLeafID.flatMap { selected in
            entries.contains(where: { $0.id == selected }) ? selected : nil
        } ?? fallbackLeaf
    }

    var activePath: [ConversationEntry] {
        guard let leafID else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var path: [ConversationEntry] = []
        var cursor: String? = leafID
        var seen = Set<String>()
        while let id = cursor, seen.insert(id).inserted, let entry = byID[id] {
            path.append(entry)
            cursor = entry.parentID
        }
        return path.reversed()
    }

    var transcript: [ConversationTranscriptRecord] {
        activePath.flatMap { entry -> [ConversationTranscriptRecord] in
            switch entry.role {
            case "user":
                if Self.isWorkspaceRelayText(entry.text) {
                    return [Self.record(.workspaceRelay, entry: entry, text: entry.text, branchable: false)]
                }
                let display = Self.displayUserText(entry.text)
                guard !display.isEmpty || entry.hasStructuredContent else { return [] }
                return [Self.record(
                    .user,
                    entry: entry,
                    text: display.isEmpty ? "Attachment" : display,
                    branchable: !entry.hasStructuredContent
                )]
            case "assistant":
                var records: [ConversationTranscriptRecord] = []
                if !entry.thinking.isEmpty {
                    records.append(Self.record(.thought, entry: entry, text: entry.thinking, branchable: true))
                }
                if !entry.text.isEmpty || !entry.images.isEmpty {
                    records.append(Self.record(
                        .assistant,
                        entry: entry,
                        text: entry.text,
                        branchable: entry.type == "message"
                    ))
                }
                return records
            case "toolResult", "bashExecution":
                return [Self.record(.tool, entry: entry, text: entry.text, branchable: false)]
            default:
                return []
            }
        }
    }

    var allWorkspaceRelayTexts: [String] {
        entries.compactMap { entry in
            guard entry.isUserMessage, Self.isWorkspaceRelayText(entry.text) else { return nil }
            return entry.text
        }
    }

    /// Branch badge counts for every user entry in one pass. The indicator
    /// consumes the whole active history, so asking `variants(around:)` once
    /// per turn would repeatedly scan and sort the same tree.
    var userVariantCountsByEntryID: [String: Int] {
        var siblingCounts: [String?: Int] = [:]
        for entry in entries where entry.isUserMessage {
            siblingCounts[entry.parentID, default: 0] += 1
        }
        return Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            guard entry.isUserMessage else { return nil }
            return (entry.id, siblingCounts[entry.parentID] ?? 1)
        })
    }

    func selecting(leafID: String?) -> ConversationTreeSnapshot {
        ConversationTreeSnapshot(entries: entries, leafID: leafID)
    }

    /// Saved selections normally name terminal branch tips. If the physical
    /// path has continued directly from that entry, the saved value is only a
    /// stale cursor and restoring it would hide the continuation. A selection
    /// on a sibling branch remains intentional and still wins.
    func restoredLeafID(savedLeafID: String?) -> String? {
        guard let savedLeafID,
              entries.contains(where: { $0.id == savedLeafID }) else {
            return leafID
        }
        guard savedLeafID != leafID else { return savedLeafID }
        if activePath.contains(where: { $0.id == savedLeafID }) {
            return leafID
        }
        return savedLeafID
    }

    func variants(around entryID: String) -> [ConversationVariant] {
        guard let selected = entries.first(where: { $0.id == entryID }), selected.isUserMessage else {
            return []
        }
        let siblings = entries
            .filter { $0.isUserMessage && $0.parentID == selected.parentID }
            .sorted { $0.order < $1.order }
        guard siblings.count > 1 else { return [] }
        let activeIDs = Set(activePath.map(\.id))
        return siblings.map { sibling in
            ConversationVariant(
                entryID: sibling.id,
                tipID: branchTip(startingAt: sibling.id),
                title: HistoryPreviewText.title(from: Self.displayUserText(sibling.text)),
                isCurrent: activeIDs.contains(sibling.id)
            )
        }
    }

    func tipID(for entryID: String) -> String {
        branchTip(startingAt: entryID)
    }

    func depth(of entryID: String) -> Int {
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var depth = 0
        var cursor = byID[entryID]?.parentID
        var seen = Set<String>()
        while let id = cursor, seen.insert(id).inserted, let entry = byID[id] {
            if entry.isUserMessage { depth += 1 }
            cursor = entry.parentID
        }
        return depth
    }

    private func branchTip(startingAt rootID: String) -> String {
        var children: [String: [ConversationEntry]] = [:]
        for entry in entries {
            if let parentID = entry.parentID {
                children[parentID, default: []].append(entry)
            }
        }
        var candidates: [ConversationEntry] = []
        var queue = [rootID]
        var seen = Set<String>()
        while let id = queue.popLast(), seen.insert(id).inserted {
            let descendants = children[id] ?? []
            if descendants.isEmpty, let entry = entries.first(where: { $0.id == id }) {
                candidates.append(entry)
            } else {
                queue.append(contentsOf: descendants.map(\.id))
            }
        }
        return candidates.max(by: { $0.order < $1.order })?.id ?? rootID
    }

    private static func parseEntry(_ raw: Any, order: Int) -> ConversationEntry? {
        guard let object = raw as? [String: Any],
              let id = string(object["id"]),
              let type = string(object["type"]) else { return nil }
        let message = object["message"] as? [String: Any] ?? [:]
        let isDisplayedCustomMessage = type == "custom_message" && bool(object["display"])
        let content = isDisplayedCustomMessage ? object["content"] : message["content"]
        let imageProjection = imageContent(content)
        return ConversationEntry(
            id: id,
            parentID: string(object["parentId"]),
            type: type,
            role: isDisplayedCustomMessage ? "assistant" : string(message["role"]),
            text: contentText(content),
            thinking: thinkingText(content),
            toolName: string(message["toolName"]) ?? string(message["command"]),
            toolCallID: string(message["toolCallId"]),
            isError: bool(message["isError"]),
            hasStructuredContent: hasStructuredContent(content),
            images: imageProjection.images,
            imageOffsets: imageProjection.offsets,
            order: order
        )
    }

    private static func contentText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [Any] else { return "" }
        return blocks.compactMap { block -> String? in
            guard let item = block as? [String: Any], string(item["type"]) == "text" else { return nil }
            return string(item["text"])
        }.joined()
    }

    private static func thinkingText(_ content: Any?) -> String {
        guard let blocks = content as? [Any] else { return "" }
        return blocks.compactMap { block -> String? in
            guard let item = block as? [String: Any], string(item["type"]) == "thinking" else { return nil }
            return string(item["thinking"])
        }.joined()
    }

    private static func hasStructuredContent(_ content: Any?) -> Bool {
        guard let blocks = content as? [Any] else { return false }
        return blocks.contains { block in
            guard let item = block as? [String: Any], let type = string(item["type"]) else { return false }
            return type != "text" && type != "thinking"
        }
    }

    private static func imageContent(
        _ content: Any?
    ) -> (images: [AssistantMessageImage], offsets: [Int]) {
        guard let blocks = content as? [Any] else { return ([], []) }
        var textOffset = 0
        var images: [AssistantMessageImage] = []
        var offsets: [Int] = []
        for block in blocks {
            guard let item = block as? [String: Any], let type = string(item["type"]) else { continue }
            if type == "text" {
                textOffset += string(item["text"])?.count ?? 0
            } else if type == "image",
                      let mimeType = string(item["mimeType"]),
                      let encoded = string(item["data"]),
                      let image = AssistantMessageImage.decode(mimeType: mimeType, encoded: encoded) {
                images.append(image)
                offsets.append(textOffset)
            }
        }
        return (images, offsets)
    }

    static func displayUserText(_ text: String) -> String {
        WorkspacePromptEnvelope.displayText(from: text)
    }

    private static func isWorkspaceRelayText(_ text: String) -> Bool {
        text.hasPrefix(
            """
            The workspace run already finished. Summarize the result for the user in your own voice, then stop.
            Do not call workspace_run, mount_workspace, bash, or any other tool.
            Do not greet. Do not repeat the goal. Do not paste this block verbatim.

            """
        )
            && text.contains("\nname: ")
            && text.contains("\npath: ")
            && text.contains("\nstatus: ")
            && text.contains("\ngoal: ")
    }

    private static func record(
        _ kind: ConversationTranscriptRecord.Kind,
        entry: ConversationEntry,
        text: String,
        branchable: Bool
    ) -> ConversationTranscriptRecord {
        ConversationTranscriptRecord(
            kind: kind,
            entryID: entry.id,
            text: text,
            toolName: entry.toolName,
            toolCallID: entry.toolCallID,
            isError: entry.isError,
            branchable: branchable,
            images: entry.images,
            imageOffsets: entry.imageOffsets
        )
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func bool(_ value: Any?) -> Bool {
        (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
    }
}

enum ConversationBranchRecovery {
    static func promptWasPersisted(
        in snapshot: ConversationTreeSnapshot,
        after targetID: String,
        navigationSucceeded: Bool = true
    ) -> Bool {
        guard navigationSucceeded else { return false }
        guard let targetOrder = snapshot.entries.first(where: { $0.id == targetID })?.order,
              let latestUserOrder = snapshot.activePath.last(where: \.isUserMessage)?.order else { return false }
        return latestUserOrder > targetOrder
    }
}

enum ConversationBranchInteraction {
    static func canSend(isSwitchingBranch: Bool) -> Bool {
        !isSwitchingBranch
    }
}

private enum HistoryPreviewText {
    static func title(from text: String) -> String {
        let line = text
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "Branch"
        guard line.count > 48 else { return line }
        let end = line.index(line.startIndex, offsetBy: 47)
        return String(line[..<end]).trimmingCharacters(in: .whitespaces) + "…"
    }
}
