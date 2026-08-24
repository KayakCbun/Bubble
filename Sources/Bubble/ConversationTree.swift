import Foundation

struct ConversationEntry: Equatable {
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

struct ConversationTranscriptRecord: Equatable {
    enum Kind: Equatable {
        case user
        case assistant
        case thought
        case tool
    }

    var kind: Kind
    var entryID: String
    var text: String
    var toolName: String?
    var toolCallID: String?
    var isError: Bool
    var branchable: Bool
}

struct ConversationTreeSnapshot: Equatable {
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
                if !entry.text.isEmpty {
                    records.append(Self.record(.assistant, entry: entry, text: entry.text, branchable: true))
                }
                return records
            case "toolResult", "bashExecution":
                return [Self.record(.tool, entry: entry, text: entry.text, branchable: false)]
            default:
                return []
            }
        }
    }

    func selecting(leafID: String?) -> ConversationTreeSnapshot {
        ConversationTreeSnapshot(entries: entries, leafID: leafID)
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
        let content = message["content"]
        return ConversationEntry(
            id: id,
            parentID: string(object["parentId"]),
            type: type,
            role: string(message["role"]),
            text: contentText(content),
            thinking: thinkingText(content),
            toolName: string(message["toolName"]) ?? string(message["command"]),
            toolCallID: string(message["toolCallId"]),
            isError: bool(message["isError"]),
            hasStructuredContent: hasStructuredContent(content),
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

    static func displayUserText(_ text: String) -> String {
        let marker = "</bubble-workspace>"
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<bubble-workspace>"),
              let range = text.range(of: marker) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
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
            branchable: branchable
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
