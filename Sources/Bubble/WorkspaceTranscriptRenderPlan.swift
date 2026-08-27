import Foundation

enum WorkspaceTranscriptChunker {
    /// Keep a newly realized text row cheap enough to lay out inside one
    /// high-refresh display interval. The outer transcript virtualizes these
    /// stable units, so smaller rows trade a little planning work for much
    /// lower scroll hitch latency.
    static let targetBytes = 700

    private static let cache: NSCache<NSString, WorkspaceTextChunksBox> = {
        let cache = NSCache<NSString, WorkspaceTextChunksBox>()
        cache.countLimit = 2_048
        cache.totalCostLimit = 24 * 1_024 * 1_024
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
        guard bytes.count > target else { return [text] }
        if containsASCII(bytes, "```") || containsASCII(bytes, "~~~") {
            return [text]
        }
        if let tableChunks = mixedGFMTableChunks(text, target: target), tableChunks.count > 1 {
            return tableChunks
        }
        guard hasParagraphLocalSemantics(bytes) else { return [text] }
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

    private static func mixedGFMTableChunks(_ text: String, target: Int) -> [String]? {
        let rowsPerChunk = 20
        let lines = text.components(separatedBy: "\n")

        func isTableRow(_ line: String) -> Bool {
            let row = line.trimmingCharacters(in: .whitespaces)
            return row.hasPrefix("|") && row.dropFirst().contains("|")
        }

        func isSeparator(_ line: String) -> Bool {
            let cells = line.split(separator: "|")
            return !cells.isEmpty && cells.allSatisfy { cell in
                let marker = cell.trimmingCharacters(in: .whitespaces)
                return !marker.isEmpty && marker.allSatisfy { $0 == "-" || $0 == ":" }
            }
        }

        guard lines.count > rowsPerChunk + 2 else { return nil }
        for tableStart in 0..<(lines.count - 1) {
            guard isTableRow(lines[tableStart]), isSeparator(lines[tableStart + 1]) else { continue }
            var tableEnd = tableStart + 2
            while tableEnd < lines.count, isTableRow(lines[tableEnd]) {
                tableEnd += 1
            }
            guard tableEnd - tableStart > rowsPerChunk + 2 else { continue }

            var chunks: [String] = []
            let prefix = lines[..<tableStart].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                chunks.append(contentsOf: buildChunks(prefix, target: target))
            }

            let header = Array(lines[tableStart..<(tableStart + 2)])
            var bodyStart = tableStart + 2
            while bodyStart < tableEnd {
                let bodyEnd = min(tableEnd, bodyStart + rowsPerChunk)
                chunks.append((header + Array(lines[bodyStart..<bodyEnd])).joined(separator: "\n"))
                bodyStart = bodyEnd
            }

            let suffix = lines[tableEnd...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !suffix.isEmpty {
                chunks.append(contentsOf: buildChunks(suffix, target: target))
            }
            return chunks
        }
        return nil
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
