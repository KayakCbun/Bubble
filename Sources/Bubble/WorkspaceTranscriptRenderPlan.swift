import Foundation

enum WorkspaceTranscriptChunker {
    static let targetBytes = 2_100

    private static let cache: NSCache<NSString, WorkspaceTextChunksBox> = {
        let cache = NSCache<NSString, WorkspaceTextChunksBox>()
        cache.countLimit = 128
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    /// Only paragraph-local prose is split. Document-scoped Markdown remains
    /// one render unit so virtualization never changes its meaning.
    static func chunks(
        _ text: String,
        identity: String? = nil,
        target: Int = targetBytes
    ) -> [String] {
        let key = (identity.map { "\($0):\(target)" } ?? "text:\(target):\(text)") as NSString
        if let cached = cache.object(forKey: key), cached.text == text {
            return cached.chunks
        }
        let chunks = buildChunks(text, target: target)
        cache.setObject(
            WorkspaceTextChunksBox(text: text, chunks: chunks),
            forKey: key,
            cost: text.utf8.count
        )
        return chunks
    }

    static func visibleEdges(_ text: String, identity: String) -> [String] {
        let chunks = chunks(text, identity: identity)
        guard chunks.count > 1 else { return chunks }
        return [chunks[0], chunks[chunks.count - 1]]
    }

    private static func buildChunks(_ text: String, target: Int) -> [String] {
        guard text.utf8.count > target, hasParagraphLocalSemantics(text) else { return [text] }
        let boundaries = paragraphBoundaries(in: text)
        guard !boundaries.isEmpty else { return [text] }

        var chunks: [String] = []
        var start = text.startIndex
        var startOffset = 0
        var lastBoundary = (index: start, offset: 0)
        for boundary in boundaries {
            if boundary.offset - startOffset > target, lastBoundary.index > start {
                chunks.append(String(text[start..<lastBoundary.index]))
                start = lastBoundary.index
                startOffset = lastBoundary.offset
            }
            lastBoundary = boundary
        }
        if start < text.endIndex {
            chunks.append(String(text[start..<text.endIndex]))
        }
        return chunks.filter { !$0.isEmpty }
    }

    static func isParagraphLocal(_ text: String) -> Bool {
        hasParagraphLocalSemantics(text)
    }

    private static func hasParagraphLocalSemantics(_ text: String) -> Bool {
        if MermaidTextDetector.firstRange(in: text) != nil { return false }
        let lower = text.lowercased()
        if lower.contains("```") || lower.contains("~~~") { return false }
        let documentMarkers = [
            "flowchart", "sequencediagram", "classdiagram", "statediagram",
            "erdiagram", "gitgraph", "xychart", "<table", "<details", "<div", "<pre", "<script",
        ]
        if documentMarkers.contains(where: lower.contains) { return false }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let loweredLine = trimmed.lowercased()
            let mermaidRoots = ["graph ", "mermaid graph ", "journey", "gantt", "pie", "mindmap"]
            if mermaidRoots.contains(where: loweredLine.hasPrefix) { return false }
        }
        guard text.contains("\n[") || text.hasPrefix("[")
                || text.contains("\n|") || text.hasPrefix("|")
                || text.contains("\n<") || text.hasPrefix("<") else {
            return true
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|"), trimmed.contains("|") { return false }
            if trimmed.hasPrefix("["), trimmed.contains("]:" ) { return false }
            if trimmed.hasPrefix("<"), trimmed.hasSuffix(">") { return false }
        }
        return true
    }

    private static func paragraphBoundaries(in text: String) -> [(index: String.Index, offset: Int)] {
        var boundaries: [(String.Index, Int)] = []
        let bytes = text.utf8
        var index = bytes.startIndex
        var offset = 0
        while index < bytes.endIndex {
            let next = bytes.index(after: index)
            if bytes[index] == 10, next < bytes.endIndex, bytes[next] == 10 {
                index = bytes.index(after: next)
                offset += 2
                if let stringIndex = String.Index(index, within: text) {
                    boundaries.append((stringIndex, offset))
                }
                continue
            }
            index = next
            offset += 1
        }
        return boundaries
    }
}

enum MermaidTextDetector {
    private static let regex = try? NSRegularExpression(
        pattern: #"(?i)(?:^|[\n：:]|\s)(?:mermaid[\s_]*)?(flowchart|graph(?:\s+[TDLRBA]{1,3})?|sequenceDiagram|classDiagram|stateDiagram(?:-v2)?|erDiagram|journey|gantt|pie|mindmap|gitGraph|xychart(?:-beta)?)\b"#,
        options: [.anchorsMatchLines]
    )

    static func firstRange(in text: String) -> Range<String.Index>? {
        guard let regex else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        if let mermaid = text[..<range.lowerBound].range(of: "mermaid", options: [.backwards, .caseInsensitive]),
           text[mermaid.upperBound..<range.lowerBound].allSatisfy({ $0.isWhitespace || $0 == "_" }) {
            return mermaid.lowerBound..<range.upperBound
        }
        return range
    }
}

private final class WorkspaceTextChunksBox {
    let text: String
    let chunks: [String]

    init(text: String, chunks: [String]) {
        self.text = text
        self.chunks = chunks
    }
}
