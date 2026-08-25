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
        let bytes = Array(text.utf8)
        guard bytes.count > target, hasParagraphLocalSemantics(bytes) else { return [text] }
        let boundaries = paragraphBoundaryOffsets(in: bytes)
        guard !boundaries.isEmpty else { return [text] }

        var chunks: [String] = []
        var start = 0
        var startOffset = 0
        var lastBoundary = 0
        for boundary in boundaries {
            if boundary - startOffset > target, lastBoundary > start {
                chunks.append(String(decoding: bytes[start..<lastBoundary], as: UTF8.self))
                start = lastBoundary
                startOffset = lastBoundary
            }
            lastBoundary = boundary
        }
        if start < bytes.count {
            chunks.append(String(decoding: bytes[start..<bytes.count], as: UTF8.self))
        }
        return chunks.filter { !$0.isEmpty }
    }

    static func isParagraphLocal(_ text: String) -> Bool {
        hasParagraphLocalSemantics(Array(text.utf8))
    }

    private static func hasParagraphLocalSemantics(_ bytes: [UInt8]) -> Bool {
        let globalMarkers = [
            "```", "~~~", "flowchart", "sequencediagram", "classdiagram",
            "statediagram", "erdiagram", "gitgraph", "xychart",
            "graph td", "graph tb", "graph bt", "graph lr", "graph rl", "<table",
            "<details", "<div", "<pre", "<script", "mermaid",
        ]
        if globalMarkers.contains(where: { containsASCII(bytes, $0) }) { return false }

        var lineStart = 0
        while lineStart < bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != 10 { lineEnd += 1 }
            var start = lineStart
            while start < lineEnd, bytes[start] == 32 || bytes[start] == 9 { start += 1 }
            var end = lineEnd
            while end > start, bytes[end - 1] == 32 || bytes[end - 1] == 9 || bytes[end - 1] == 13 {
                end -= 1
            }
            if start < end {
                let line = bytes[start..<end]
                let roots = ["graph ", "journey", "gantt", "pie", "mindmap"]
                if roots.contains(where: { hasASCIIPrefix(line, $0) }) { return false }
                if line.first == 124, line.dropFirst().contains(124) { return false }
                if line.first == 91, containsASCII(Array(line), "]:") { return false }
                if line.first == 60, line.last == 62 { return false }
            }
            lineStart = lineEnd + 1
        }
        return true
    }

    private static func containsASCII(_ bytes: [UInt8], _ pattern: String) -> Bool {
        let needle = Array(pattern.utf8)
        guard !needle.isEmpty, needle.count <= bytes.count else { return false }
        for start in 0...(bytes.count - needle.count) {
            var matches = true
            for offset in needle.indices where asciiLower(bytes[start + offset]) != asciiLower(needle[offset]) {
                matches = false
                break
            }
            if matches { return true }
        }
        return false
    }

    private static func hasASCIIPrefix(_ bytes: ArraySlice<UInt8>, _ prefix: String) -> Bool {
        let needle = Array(prefix.utf8)
        guard needle.count <= bytes.count else { return false }
        for (offset, expected) in needle.enumerated() {
            if asciiLower(bytes[bytes.index(bytes.startIndex, offsetBy: offset)]) != asciiLower(expected) {
                return false
            }
        }
        return true
    }

    private static func asciiLower(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }

    private static func paragraphBoundaryOffsets(in bytes: [UInt8]) -> [Int] {
        var boundaries: [Int] = []
        boundaries.reserveCapacity(max(1, bytes.count / targetBytes))
        var index = 0
        while index + 1 < bytes.count {
            if bytes[index] == 10, bytes[index + 1] == 10 {
                index += 2
                boundaries.append(index)
            } else {
                index += 1
            }
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
