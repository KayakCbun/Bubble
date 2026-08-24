import Foundation

/// Streaming rules for assistant text and nested workspace thoughts.
/// Thought chunks must not open a new bubble; consecutive thought tokens
/// belong to one Thoughts row.
enum TranscriptStream {
    static let childCap = 40

    struct WorkspaceRunRecord: Equatable {
        var path: String
        var runId: String?
        var sessionId: String?
        var goal: String
        var status: String?
        var summary: String
        var anchorEntryId: String?
    }

    /// Whether a workspace-child thought chunk should append to the last child.
    static func shouldMergeThought(previousKind: String?) -> Bool {
        previousKind == "thought"
    }

    /// Find the in-flight assistant bubble for this turn.
    /// Trailing thoughts and workspace cards are skipped so a late thought
    /// token does not start a second assistant message. Tools, user, and
    /// system items end the bubble.
    static func resumeAssistantIndex(kinds: [String]) -> Int? {
        var index = kinds.count - 1
        while index >= 0 {
            switch kinds[index] {
            case "thought", "workspaceRun":
                index -= 1
            case "assistant":
                return index
            default:
                return nil
            }
        }
        return nil
    }

    static func cappedChildren<T>(_ children: [T], cap: Int = childCap) -> [T] {
        children.count > cap ? Array(children.suffix(cap)) : children
    }

    /// Join two streamed pieces. CJK stays glued; Latin words get a space
    /// when the original leading space was stripped from a saved chunk.
    static func joinText(_ left: String, _ right: String) -> String {
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        if joinNeedsSpace(left, right) {
            return left + " " + right
        }
        return left + right
    }

    /// Update the live card only if this run is still in flight and the user
    /// has not spoken since. A later user turn always opens a new card.
    static func shouldReuseWorkspaceCard(
        existingStatus: String?,
        userSpokeAfter: Bool,
        sameRun: Bool = false
    ) -> Bool {
        if sameRun { return true }
        if userSpokeAfter { return false }
        return existingStatus == "running" || existingStatus == "waiting"
    }

    static func deduplicateWorkspaceRuns(_ records: [WorkspaceRunRecord]) -> [WorkspaceRunRecord] {
        var result: [WorkspaceRunRecord] = []
        for record in records {
            if let index = result.firstIndex(where: { areDuplicateWorkspaceRuns($0, record) }) {
                if result[index].anchorEntryId == nil, record.anchorEntryId != nil {
                    result[index] = record
                }
            } else {
                result.append(record)
            }
        }
        return result
    }

    static func areDuplicateWorkspaceRuns(_ lhs: WorkspaceRunRecord, _ rhs: WorkspaceRunRecord) -> Bool {
        guard lhs.path == rhs.path, lhs.goal == rhs.goal else { return false }
        if let left = lhs.runId, !left.isEmpty,
           let right = rhs.runId, !right.isEmpty {
            return left == right
        }
        if let left = lhs.anchorEntryId, let right = rhs.anchorEntryId {
            return left == right
        }
        guard lhs.runId == rhs.runId,
              lhs.sessionId == rhs.sessionId,
              lhs.status == rhs.status else { return false }
        return legacySummariesMatch(lhs.summary, rhs.summary)
    }

    private static func legacySummariesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if left == right { return true }
        let leftPrefix = left.trimmingCharacters(in: CharacterSet(charactersIn: "…"))
        let rightPrefix = right.trimmingCharacters(in: CharacterSet(charactersIn: "…"))
        guard min(leftPrefix.count, rightPrefix.count) >= 12 else { return false }
        return leftPrefix.hasPrefix(rightPrefix) || rightPrefix.hasPrefix(leftPrefix)
    }

    static func canMergeAdjacent(previous: String?, next: String) -> Bool {
        guard let previous else { return false }
        return previous == next && next == "thought"
    }

    /// Only glue the old one-character stream split, not two real replies.
    static func shouldGlueSplitAssistant(_ previous: String, _ next: String) -> Bool {
        let left = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return false }
        guard left.count <= 24 else { return false }
        return !left.contains(where: { "。！？\n".contains($0) })
    }

    /// Session resume used to append older replies onto the last bubble.
    static func truncatedAssistant(_ text: String, earlier: [String]) -> String {
        var text = collapseSelfRepeat(text)
        for snippet in earlier {
            let piece = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            guard piece.count >= 24 else { continue }
            if let range = text.range(of: piece), range.lowerBound > text.startIndex {
                text = String(text[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    static func collapseSelfRepeat(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 24 else { return text }
        let mid = trimmed.count / 2
        for split in [mid, mid - 1, mid + 1] {
            guard split > 8, split < trimmed.count else { continue }
            let index = trimmed.index(trimmed.startIndex, offsetBy: split)
            let left = trimmed[..<index].trimmingCharacters(in: .whitespacesAndNewlines)
            let right = trimmed[index...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !left.isEmpty, left == right {
                return String(left)
            }
        }
        return text
    }

    struct Node: Equatable {
        var kind: String
        var text: String
        var children: [Node] = []
    }

    /// Repair a saved transcript: glue adjacent assistant/thought bubbles
    /// and consecutive workspace thought children.
    static func coalesce(_ items: [Node]) -> [Node] {
        var result: [Node] = []
        for var item in items {
            if item.kind == "workspaceRun" {
                item.children = coalesceChildren(item.children)
            }
            if canMergeAdjacent(previous: result.last?.kind, next: item.kind) {
                result[result.count - 1].text = joinText(result[result.count - 1].text, item.text)
            } else if result.last?.kind == "assistant",
                      item.kind == "assistant",
                      let last = result.last,
                      shouldGlueSplitAssistant(last.text, item.text) {
                result[result.count - 1].text = joinText(last.text, item.text)
            } else {
                result.append(item)
            }
        }
        var earlier: [String] = []
        for index in result.indices where result[index].kind == "assistant" {
            result[index].text = truncatedAssistant(result[index].text, earlier: earlier)
            if !result[index].text.isEmpty {
                earlier.append(result[index].text)
            }
        }
        return result.filter { item in
            item.kind != "assistant" || !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func coalesceChildren(_ children: [Node]) -> [Node] {
        var result: [Node] = []
        for item in children {
            if item.kind == "thought",
               item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            if shouldMergeThought(previousKind: result.last?.kind), item.kind == "thought" {
                result[result.count - 1].text = joinText(result[result.count - 1].text, item.text)
            } else {
                result.append(item)
            }
        }
        return cappedChildren(result)
    }

    private static func joinNeedsSpace(_ left: String, _ right: String) -> Bool {
        guard let last = left.last, let first = right.first else { return false }
        if last.isWhitespace || first.isWhitespace { return false }
        func latin(_ ch: Character) -> Bool {
            ch.isASCII && (ch.isLetter || ch.isNumber)
        }
        if latin(last) && latin(first) { return true }
        if latin(last) && !first.isPunctuation { return true }
        if latin(first) && !"，。、；：,.;:）)]}".contains(last) { return true }
        return false
    }
}
