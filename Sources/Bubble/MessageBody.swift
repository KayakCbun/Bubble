import AppKit
import SwiftUI
import MarkdownUI
import BeautifulMermaid
import BubbleDiagramSupport
import WebKit

private enum MarkdownContentPreparation {
    static let layoutVersion = 2

    static func content(_ markdown: String, completed: Bool) -> MarkdownContent {
        guard completed else { return MarkdownContent(markdown) }
        // MarkdownContent only stores MarkdownUI's parsed block tree. Theme,
        // colors, fonts, and width are applied later by the Markdown view.
        let fingerprint = ProseTypographyFingerprint.contentOnly(layoutVersion: layoutVersion)
        let key = ProseRenderKey(text: markdown, width: 0, typography: fingerprint, variant: 10)
        return ProseRenderCache.shared.cachedObject(
            for: key,
            variant: "markdown-content",
            completed: completed,
            estimatedBytes: max(512, markdown.utf8.count * 4)
        ) {
            MarkdownContent(markdown)
        }
    }
}

struct MessageBody: View {
    var text: String
    var streaming: Bool = false
    /// The outer transcript planner may split one large structured block into
    /// bounded rows. Make the local copy affordance explicit in that case.
    var virtualizedChunk: Bool = false
    /// File previews always go through MarkdownUI. Chat bubbles stay on ProseDocument
    /// unless the slice is a table or a leading fence MarkdownUI already owns.
    var preferClassicMarkdown: Bool = false

    @ViewBuilder
    var body: some View {
        if preferClassicMarkdown {
            LazyVStack(alignment: .leading, spacing: 16) {
                messageParts
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                messageParts
            }
        }
    }

    @ViewBuilder
    private var messageParts: some View {
        ForEach(Array(MessagePart.displayParts(text, completed: !streaming).enumerated()), id: \.offset) { _, part in
            switch part {
            case .markdown(let markdown):
                if preferClassicMarkdown || PathChipStyle.needsClassicMarkdown(markdown) {
                    Markdown(MarkdownContentPreparation.content(markdown, completed: !streaming))
                        .markdownTheme(.overlay)
                        .markdownTextStyle(\.text) {
                            FontSize(OverlayMetrics.fontSize)
                            FontWeight(.regular)
                        }
                        .font(OverlayMetrics.bodyFont)
                        .bubbleTextSelection()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProseDocument(text: markdown, streaming: streaming)
                }
            case .code(let language, let body):
                CodeBlockView(
                    language: language,
                    source: body,
                    streaming: streaming,
                    virtualizedChunk: virtualizedChunk
                )
            case .mermaid(let source):
                MermaidView(source: MessagePart.normalizeMermaid(source), streaming: streaming)
            case .math(let expression):
                Text(MarkdownMath.nativeExpression(expression) ?? expression)
                    .font(.system(size: OverlayMetrics.fontSize + 2, design: .serif))
                    .foregroundStyle(OverlaySurface.conversationInk)
                    .bubbleTextSelection()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
                    .accessibilityLabel(expression)
            }
        }
    }
}

enum MessagePart {
    case markdown(String)
    case code(language: String, body: String)
    case mermaid(String)
    case math(String)

    static func displayParts(_ text: String, completed: Bool = true) -> [MessagePart] {
        guard completed else { return parseDisplayParts(text) }
        return MessagePartCache.shared.parts(for: text) {
            parseDisplayParts(text)
        }
    }

    static func prewarmDisplay(_ text: String) {
        for part in displayParts(text) {
            if case .markdown(let markdown) = part,
               !PathChipStyle.needsClassicMarkdown(markdown) {
                _ = ProseParser.blocks(in: markdown)
            }
        }
    }

    private static func parseDisplayParts(_ text: String) -> [MessagePart] {
        var parts: [MessagePart] = []
        for part in split(text) {
            switch part {
            case .mermaid, .code, .math:
                parts.append(part)
            case .markdown(let markdown):
                let normalized = normalizeMarkdown(markdown)
                for mathPart in MarkdownMath.splitBlocks(normalized) {
                    switch mathPart {
                    case .text(let text):
                        parts.append(contentsOf: splitTables(text))
                    case .display(let expression):
                        parts.append(.math(expression))
                    }
                }
            }
        }
        return parts.isEmpty ? [.markdown(text)] : parts
    }

    static func split(_ text: String) -> [MessagePart] {
        var parts: [MessagePart] = []
        var remaining = text
        while !remaining.isEmpty {
            guard let fence = nextFence(in: remaining) else {
                appendSplitUnfenced(remaining, into: &parts)
                break
            }
            if !fence.before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                appendSplitUnfenced(fence.before, into: &parts)
            }
            if fence.isMermaid {
                parts.append(.mermaid(mermaidSource(language: fence.language, body: fence.body)))
            } else {
                parts.append(.code(language: fence.language, body: fence.body))
            }
            remaining = fence.after
        }
        return parts.isEmpty ? [.markdown(text)] : parts
    }

    private struct FenceMatch {
        var before: String
        var language: String
        var body: String
        var after: String
        var closed: Bool
        var isMermaid: Bool
    }

    private static func nextFence(in text: String) -> FenceMatch? {
        guard let start = text.range(of: "```") else { return nil }
        let before = String(text[..<start.lowerBound])
        var rest = text[start.upperBound...]
        var language = ""
        while let ch = rest.first, ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
            language.append(ch)
            rest.removeFirst()
        }
        while rest.first == " " || rest.first == "\t" {
            rest.removeFirst()
        }
        if rest.first == "\r" { rest.removeFirst() }
        if rest.first == "\n" { rest.removeFirst() }
        let closed: Bool
        let body: String
        let after: String
        if let end = rest.range(of: "```") {
            body = String(rest[..<end.lowerBound])
            after = String(rest[end.upperBound...])
            closed = true
        } else {
            body = String(rest)
            after = ""
            closed = false
        }
        let combined = language + "\n" + body
        let mermaid = language.lowercased() == "mermaid"
            || language.lowercased().hasPrefix("mermaid")
            || looksLikeMermaid(combined)
        return FenceMatch(
            before: before,
            language: language,
            body: body,
            after: after,
            closed: closed,
            isMermaid: mermaid
        )
    }

    private static func mermaidSource(language: String, body: String) -> String {
        let lower = language.lowercased()
        if lower == "mermaid" {
            return body
        }
        if lower.hasPrefix("mermaid") {
            return String(language.dropFirst(7)) + "\n" + body
        }
        return body
    }

    private static func appendSplitUnfenced(_ raw: String, into parts: inout [MessagePart]) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let match = MermaidTextDetector.firstRange(in: text) else {
            parts.append(.markdown(text))
            return
        }
        let before = String(text[..<match.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = String(text[match.lowerBound...])
        let split = splitMermaidTail(rest)
        if !before.isEmpty {
            parts.append(.markdown(before))
        }
        parts.append(.mermaid(split.diagram))
        if !split.after.isEmpty {
            parts.append(.markdown(split.after))
        }
    }

    private static func splitMermaidTail(_ text: String) -> (diagram: String, after: String) {
        var normalized = text
            .replacingOccurrences(of: "│", with: "\n")
            .replacingOccurrences(of: "┃", with: "\n")
            .replacingOccurrences(of: "║", with: "\n")
        if newlineCount(normalized) < 4,
           normalized.contains("|"),
           !normalized.contains("---"),
           !normalized.contains("-->"),
           !normalized.contains("-.->"),
           !normalized.contains("==>") {
            normalized = normalized.replacingOccurrences(of: "|", with: "\n")
        }
        let lines = normalized.components(separatedBy: .newlines)
        var diagram: [String] = []
        var after: [String] = []
        var inDiagram = true
        for line in lines {
            if inDiagram, isMermaidLine(line) || (diagram.count < 2 && line.trimmingCharacters(in: .whitespaces).isEmpty) {
                let (code, extra) = peelMermaidLine(line)
                diagram.append(code)
                if !extra.isEmpty {
                    inDiagram = false
                    after.append(extra)
                }
            } else if inDiagram, diagram.count < 3, !looksLikeProse(line) {
                diagram.append(line)
            } else if inDiagram, isMermaidLine(line) {
                let (code, extra) = peelMermaidLine(line)
                diagram.append(code)
                if !extra.isEmpty {
                    inDiagram = false
                    after.append(extra)
                }
            } else {
                inDiagram = false
                after.append(line)
            }
        }
        return (
            diagram.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            after.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func isMermaidLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        if t.hasPrefix("flowchart") || t.hasPrefix("graph ") || t.hasPrefix("sequenceDiagram") {
            return true
        }
        let prefixes = ["subgraph", "end", "participant", "Note", "class ", "state ", "click ", "style ", "linkStyle", "direction "]
        if prefixes.contains(where: { t.hasPrefix($0) }) { return true }
        if t.contains("-->") || t.contains("---") || t.contains("-.->") || t.contains("==>") { return true }
        if t.contains("[\"") || t.contains("{\"") || t.contains("((\"") || t.contains("[[") { return true }
        if t.contains("-->|") || t.contains("|") && t.contains("-->") { return true }
        if t.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\s*(\[[^\]]*\]|\{[^}]*\}|\([^)]*\))"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func looksLikeProse(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return false }
        let lower = t.lowercased()
        if lower.hasPrefix("file:") || lower.hasPrefix("file：") { return true }
        if t.hasPrefix("文件") || t.hasPrefix("需要") || t.hasPrefix("要点") || t.hasPrefix("说明") || t.hasPrefix("渲染") {
            return true
        }
        if lower.hasPrefix("http") { return true }
        if t.contains("文件：") || t.contains("文件:") { return true }
        return false
    }

    private static func isGluedProse(_ extra: String) -> Bool {
        let t = extra.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return false }
        if t.hasPrefix("-->") || t.hasPrefix("--") || t.hasPrefix("==") || t.hasPrefix("-.") || t.hasPrefix("|") {
            return false
        }
        let lower = t.lowercased()
        if lower.hasPrefix("file:") || lower.hasPrefix("file：") { return true }
        if t.hasPrefix("文件") || t.hasPrefix("需要") { return true }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return true }
        if let first = t.first, isCJK(first) { return true }
        return false
    }

    private static func peelMermaidLine(_ line: String) -> (String, String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        var index = t.startIndex
        while index < t.endIndex {
            let ch = t[index]
            if ch == "]" || ch == "}" || ch == ")" {
                let after = t.index(after: index)
                let extra = String(t[after...])
                if isGluedProse(extra) {
                    let code = String(t[..<after]).trimmingCharacters(in: .whitespaces)
                    return (code, extra.trimmingCharacters(in: .whitespaces))
                }
            }
            index = t.index(after: index)
        }
        return (t, "")
    }

    private static func looksLikeMermaid(_ body: String) -> Bool {
        MermaidTextDetector.firstRange(in: body) != nil
    }

    private static func newlineCount(_ text: String) -> Int {
        text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }

    static func normalizeMermaid(_ raw: String) -> String {
        var source = raw
            .replacingOccurrences(of: "│", with: "\n")
            .replacingOccurrences(of: "┃", with: "\n")
            .replacingOccurrences(of: "║", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "<br>")
            .replacingOccurrences(of: "<br />", with: "<br>")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = source.lowercased()
        if lowered.hasPrefix("mermaid") {
            source = String(source.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if newlineCount(source) < 4,
           source.contains("|"),
           !source.contains("---"),
           !source.contains("-->"),
           !source.contains("-.->"),
           !source.contains("==>") {
            source = source.replacingOccurrences(of: "|", with: "\n")
        }
        let lines = source
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var kept: [String] = []
        for line in lines {
            if looksLikeProse(line), !kept.isEmpty { break }
            let (code, extra) = peelMermaidLine(line)
            if !code.isEmpty {
                kept.append(code)
            }
            if !extra.isEmpty { break }
        }
        return MermaidSource.normalize(
            joinDirectionLine(insertMermaidNewlines(kept.joined(separator: "\n")))
        )
    }

    private static func joinDirectionLine(_ source: String) -> String {
        var lines = source.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count - 1 {
            let current = lines[index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let next = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            let direction = next.prefix(2).uppercased()
            if (current == "graph" || current == "flowchart"),
               ["TD", "TB", "BT", "LR", "RL"].contains(String(direction)) {
                lines[index] = lines[index].trimmingCharacters(in: .whitespaces) + " " + next
                lines.remove(at: index + 1)
                continue
            }
            index += 1
        }
        return lines.joined(separator: "\n")
    }

    private static func insertMermaidNewlines(_ source: String) -> String {
        if newlineCount(source) >= 8 { return source }
        let keywords = ["subgraph", "flowchart", "graph", "sequenceDiagram", "classDiagram", "stateDiagram-v2", "stateDiagram", "erDiagram", "end"]
        var result = ""
        var index = source.startIndex
        var inQuote = false
        while index < source.endIndex {
            let ch = source[index]
            if ch == "\"" {
                inQuote.toggle()
                result.append(ch)
                index = source.index(after: index)
                continue
            }
            if !inQuote {
                let remain = source[index...]
                var matched: String?
                for key in keywords {
                    guard remain.lowercased().hasPrefix(key.lowercased()) else { continue }
                    let after = source.index(index, offsetBy: key.count, limitedBy: source.endIndex) ?? source.endIndex
                    let nextOK = after == source.endIndex
                        || source[after].isWhitespace
                        || source[after] == "["
                        || source[after] == "\n"
                    let prevOK = result.last.map { $0.isWhitespace || $0.isNewline || $0 == "]" || $0 == ")" || $0 == "}" } ?? true
                    if nextOK && prevOK {
                        matched = String(source[index..<after])
                        break
                    }
                }
                if let key = matched {
                    if !result.isEmpty, result.last != "\n" {
                        result.append("\n")
                    }
                    result.append(key)
                    index = source.index(index, offsetBy: key.count)
                    if key.lowercased() == "end" {
                        result.append("\n")
                    }
                    continue
                }
            }
            result.append(ch)
            index = source.index(after: index)
        }
        return result
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func nativeMermaidSource(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"<br\s*/?>"#, with: " ", options: [.regularExpression, .caseInsensitive])
    }

    static func normalizeMarkdown(_ raw: String) -> String {
        var text = convertTables(raw)
        if !text.contains("\n- "), text.contains("•") {
            text = text.replacingOccurrences(of: "• ", with: "\n- ")
            text = text.replacingOccurrences(of: "•", with: "\n- ")
        }
        text = ProseReflow.reflow(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitTables(_ raw: String) -> [MessagePart] {
        let lines = raw.components(separatedBy: "\n")
        var parts: [MessagePart] = []
        var prose: [String] = []
        var table: [String] = []

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                parts.append(.markdown(text))
            }
            prose.removeAll()
        }

        func flushTable() {
            let rowsPerPart = 20
            if table.count > rowsPerPart + 2,
               table.count >= 2,
               isSeparatorLine(table[1]) {
                let header = Array(table.prefix(2))
                var bodyStart = 2
                while bodyStart < table.count {
                    let bodyEnd = min(table.count, bodyStart + rowsPerPart)
                    parts.append(.markdown((header + Array(table[bodyStart..<bodyEnd])).joined(separator: "\n")))
                    bodyStart = bodyEnd
                }
            } else {
                let text = table.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    parts.append(.markdown(text))
                }
            }
            table.removeAll()
        }

        func isGFMTableLine(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("|") && t.contains("|")
        }

        var index = 0
        while index < lines.count {
            if isGFMTableLine(lines[index]) {
                flushProse()
                while index < lines.count, isGFMTableLine(lines[index]) {
                    table.append(lines[index])
                    index += 1
                }
                flushTable()
                continue
            }
            prose.append(lines[index])
            index += 1
        }
        flushProse()
        return parts.isEmpty ? [.markdown(raw)] : parts
    }

    private static let columnSepChars = CharacterSet(charactersIn: "|│┃║")

    private static func columnBreaks(_ line: String) -> Int {
        line.unicodeScalars.reduce(0) { $0 + (columnSepChars.contains($1) ? 1 : 0) }
    }

    private static func isSeparatorLine(_ line: String) -> Bool {
        let parts = cells(from: line)
        guard !parts.isEmpty else { return false }
        var sawDash = false
        for cell in parts {
            let t = cell.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            guard t.allSatisfy({ $0 == "-" || $0 == "=" || $0 == ":" }) else { return false }
            if t.contains("-") || t.contains("=") { sawDash = true }
        }
        return sawDash
    }

    private static func isTableCandidate(_ line: String, next: String?) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if isSeparatorLine(t) { return true }
        let n = columnBreaks(t)
        if t.hasPrefix("|"), n >= 2 { return true }
        if n >= 2, let next {
            let nxt = next.trimmingCharacters(in: .whitespaces)
            if isSeparatorLine(nxt) || nxt.hasPrefix("|") { return true }
        }
        return false
    }

    private static func cells(from line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if let first = s.first, ["|", "│", "┃", "║"].contains(String(first)) {
            s.removeFirst()
        }
        if let last = s.last, ["|", "│", "┃", "║"].contains(String(last)) {
            s.removeLast()
        }
        var row = s.components(separatedBy: columnSepChars).map { $0.trimmingCharacters(in: .whitespaces) }
        while row.last?.isEmpty == true {
            row.removeLast()
        }
        return row
    }

    private static func splitTablePrefix(_ line: String) -> (String, String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, ["|", "│", "┃", "║"].contains(String(first)) {
            return ("", line)
        }
        guard let idx = line.firstIndex(where: { $0 == "|" || $0 == "│" || $0 == "┃" || $0 == "║" }) else {
            return ("", line)
        }
        let before = String(line[..<idx])
        if before.count > 20, let colon = before.lastIndex(where: { $0 == "：" || $0 == ":" }) {
            let prefix = String(before[...colon])
            let firstCell = String(before[before.index(after: colon)...])
            return (prefix, firstCell + String(line[idx...]))
        }
        return ("", line)
    }

    private static func isCJK(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    private static func peelTail(fromLastCell cell: String) -> (String, String) {
        guard cell.contains("•"), let bullet = cell.firstIndex(of: "•") else {
            return (cell, "")
        }
        var i = bullet
        while i > cell.startIndex {
            let prev = cell.index(before: i)
            if cell[prev].isWhitespace || isCJK(cell[prev]) {
                i = prev
                continue
            }
            break
        }
        let head = String(cell[..<i]).trimmingCharacters(in: .whitespaces)
        let tail = String(cell[i...]).trimmingCharacters(in: .whitespaces)
        if head.isEmpty { return (cell, "") }
        return (head, tail)
    }

    private static func gfmTable(_ rows: [[String]]) -> String {
        guard let header = rows.first, !header.isEmpty else { return "" }
        let width = max(header.count, rows.map(\.count).max() ?? header.count)
        func padded(_ row: [String]) -> [String] {
            var next = row
            while next.count < width { next.append("") }
            if next.count > width { next = Array(next.prefix(width)) }
            return next
        }
        func emit(_ row: [String]) -> String {
            "| " + padded(row).map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
        }
        var lines = [emit(header), "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"]
        for row in rows.dropFirst() {
            if row.allSatisfy(\.isEmpty) { continue }
            lines.append(emit(row))
        }
        return lines.joined(separator: "\n")
    }

    private static func convertTables(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let next = i + 1 < lines.count ? lines[i + 1] : nil
            guard isTableCandidate(lines[i], next: next) else {
                out.append(lines[i])
                i += 1
                continue
            }
            let (prefix, first) = splitTablePrefix(lines[i])
            var block = [first]
            i += 1
            while i < lines.count {
                let look = i + 1 < lines.count ? lines[i + 1] : nil
                if isTableCandidate(lines[i], next: look) {
                    block.append(lines[i])
                    i += 1
                } else {
                    break
                }
            }
            let hadSeparator = block.contains(where: isSeparatorLine)
            var parsed: [[String]] = []
            for line in block where !isSeparatorLine(line) {
                let row = cells(from: line)
                if row.contains(where: { !$0.isEmpty }) {
                    parsed.append(row)
                }
            }
            var tail = ""
            if parsed.count >= 1, let lastCell = parsed[parsed.count - 1].last {
                let (cell, extra) = peelTail(fromLastCell: lastCell)
                if !extra.isEmpty {
                    parsed[parsed.count - 1][parsed[parsed.count - 1].count - 1] = cell
                    tail = extra
                }
            }
            let usable = parsed.count >= 2 || (parsed.count >= 1 && hadSeparator && (parsed.first?.count ?? 0) >= 2)
            if usable {
                if !prefix.trimmingCharacters(in: .whitespaces).isEmpty {
                    out.append(prefix.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if let last = out.last, !last.isEmpty {
                    out.append("")
                }
                out.append(gfmTable(parsed))
                out.append("")
                if !tail.isEmpty {
                    out.append(tail)
                }
            } else {
                if !prefix.isEmpty { out.append(prefix) }
                out.append(contentsOf: block)
            }
        }
        return out.joined(separator: "\n")
    }
}

private final class MessagePartBox {
    let parts: [MessagePart]

    init(_ parts: [MessagePart]) {
        self.parts = parts
    }
}

private final class MessagePartCache {
    static let shared = MessagePartCache()

    private let cache: NSCache<NSString, MessagePartBox> = {
        let cache = NSCache<NSString, MessagePartBox>()
        cache.countLimit = 256
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    func parts(for text: String, build: () -> [MessagePart]) -> [MessagePart] {
        let key = text as NSString
        if let cached = cache.object(forKey: key) {
            return cached.parts
        }
        let parts = build()
        cache.setObject(MessagePartBox(parts), forKey: key, cost: text.utf8.count)
        return parts
    }
}

private extension Theme {
    static let overlay = Theme.gitHub
        .text {
            FontSize(OverlayMetrics.fontSize)
            FontWeight(.regular)
            ForegroundColor(OverlaySurface.conversationInk)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(OverlayMetrics.chipSize)
            FontWeight(.regular)
            ForegroundColor(OverlaySurface.conversationInk)
            BackgroundColor(OverlaySurface.chipFill)
        }
        .heading1 { configuration in
            configuration.label
                .relativeLineSpacing(.em(OverlaySurface.proseHeadingLineSpacingEm))
                .markdownTextStyle { FontWeight(.semibold); FontSize(OverlayMetrics.heading1Size) }
                .markdownMargin(top: 20, bottom: 8)
        }
        .heading2 { configuration in
            configuration.label
                .relativeLineSpacing(.em(OverlaySurface.proseHeadingLineSpacingEm))
                .markdownTextStyle { FontWeight(.semibold); FontSize(OverlayMetrics.heading2Size) }
                .markdownMargin(top: 20, bottom: 8)
        }
        .heading3 { configuration in
            configuration.label
                .relativeLineSpacing(.em(OverlaySurface.proseHeadingLineSpacingEm))
                .markdownTextStyle { FontWeight(.semibold); FontSize(OverlayMetrics.heading3Size) }
                .markdownMargin(top: 16, bottom: 8)
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(OverlaySurface.proseLineSpacingEm))
                .markdownMargin(top: 0, bottom: OverlaySurface.proseBlockSpacing)
        }
        .listItem { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(OverlaySurface.proseLineSpacingEm))
                .markdownMargin(top: 10, bottom: 0)
        }
        .codeBlock { configuration in
            CodeBlockView(language: configuration.language ?? "", source: configuration.content)
                .markdownMargin(top: 6, bottom: 14)
        }
        .table { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .fixedSize(horizontal: true, vertical: true)
                    .markdownTableBorderStyle(.init(color: Color.primary.opacity(0.16), width: 0.5))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(Color.clear, Color.primary.opacity(0.045))
                    )
            }
            .markdownMargin(top: 8, bottom: 16)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(OverlayMetrics.fontSize)
                    if configuration.row == 0 {
                        FontWeight(.medium)
                    } else {
                        FontWeight(.regular)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .relativeLineSpacing(.em(0.40))
        }
}

struct CodeBlockView: View {
    var language: String
    var source: String
    var streaming = false
    var virtualizedChunk = false

    @State private var copied = false
    @State private var wrap = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(virtualizedChunk ? "\(displayLanguage) · section" : displayLanguage)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                codeChromeButton(wrap ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    wrap.toggle()
                }
                .help(wrap ? "Scroll horizontally" : "Wrap lines")
                codeChromeButton(copied ? "checkmark" : "square.on.square") {
                    copy()
                }
                .help(virtualizedChunk ? "Copy this virtualized section" : "Copy")
            }
            Group {
                if streaming {
                    let tail = source.suffix(CodeDisplayChunker.targetCharacters)
                    VStack(alignment: .leading, spacing: 6) {
                        if tail.startIndex != source.startIndex {
                            Text("Earlier code stays virtualized while this block streams…")
                                .font(.system(size: 10.5, weight: .regular))
                                .foregroundStyle(.tertiary)
                        }
                        Text(String(tail))
                            .font(.system(size: OverlayMetrics.codeSize, weight: .regular, design: .monospaced))
                            .foregroundStyle(OverlayMetrics.ink.opacity(0.88))
                            .bubbleTextSelection()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if wrap {
                    wrappedCode
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(source)
                            .font(.system(size: OverlayMetrics.codeSize, weight: .regular, design: .monospaced))
                            .foregroundStyle(OverlayMetrics.ink.opacity(0.88))
                            .bubbleTextSelection()
                            .fixedSize(horizontal: true, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OverlaySurface.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(OverlaySurface.chipStroke, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var wrappedCode: some View {
        let chunks = CodeDisplayChunker.chunks(source)
        if source.count > CodeDisplayChunker.targetCharacters {
            LazyVStack(alignment: .leading, spacing: 0) {
                codeChunks(chunks)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                codeChunks(chunks)
            }
        }
    }

    @ViewBuilder
    private func codeChunks(_ chunks: [String]) -> some View {
        ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
            Text(chunk.hasSuffix("\n") ? String(chunk.dropLast()) : chunk)
                .font(.system(size: OverlayMetrics.codeSize, weight: .regular, design: .monospaced))
                .foregroundStyle(OverlayMetrics.ink.opacity(0.88))
                .bubbleTextSelection()
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var displayLanguage: String {
        CodeLanguage.displayName(language, body: source)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copied = false
        }
    }

    private func codeChromeButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }
}

enum CodeLanguage {
    static func displayName(_ raw: String, body: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmed.isEmpty {
            return trimmed
        }
        return infer(body)
    }

    static func infer(_ body: String) -> String {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "text" }
        if text.hasPrefix("{") || text.hasPrefix("[") { return "json" }
        if text.hasPrefix("<") { return "xml" }
        if text.hasPrefix("#!") { return "shell" }
        let head = text.prefix(120).lowercased()
        if head.contains("select ") || head.contains(" from ") { return "sql" }
        if head.contains("func ") && head.contains("->") { return "swift" }
        if head.contains("def ") || head.contains("import ") { return "python" }
        return "text"
    }
}

struct MermaidView: View {
    var source: String
    var streaming: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?
    @State private var useWeb = false
    @State private var webFailed = false
    @State private var webHeight: CGFloat = 180
    @State private var renderID = UUID()

    var body: some View {
        Group {
            if let image, !useWeb {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            } else if useWeb, !webFailed, MermaidResources.directory != nil {
                MermaidWKView(source: source, height: $webHeight, failed: $webFailed)
                    .frame(maxWidth: .infinity)
                    .frame(height: webHeight)
                    .allowsHitTesting(false)
            } else if streaming, image == nil {
                Text("Drawing diagram…")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                Text(source)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .bubbleTextSelection()
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !streaming else { return }
            MermaidZoomController.shared.show(source: source, image: image)
        }
        .overlay(alignment: .topTrailing) {
            if image != nil || (useWeb && !webFailed) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering in
            if hovering, !streaming {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .help("Click to enlarge")
        .onAppear { enqueueRender() }
        .onChange(of: source) { _, _ in enqueueRender() }
        .onChange(of: streaming) { _, _ in enqueueRender() }
        .onChange(of: colorScheme) { _, _ in enqueueRender() }
        .onChange(of: webFailed) { _, failed in
            if failed, image == nil, !streaming {
                OverlayLog.write("mermaid.js fallback failed")
            }
        }
    }

    private func enqueueRender() {
        let token = UUID()
        renderID = token
        webFailed = false
        if streaming {
            image = nil
            useWeb = false
            return
        }
        if useWeb {
            return
        }
        let src = source
        let dark = colorScheme == .dark
        DispatchQueue.main.async {
            guard renderID == token else { return }
            renderNative(src, dark: dark, token: token)
        }
    }

    private func renderNative(_ src: String, dark: Bool, token: UUID) {
        var theme = dark ? DiagramTheme.zincDark : DiagramTheme.zincLight
        theme.transparent = true
        MermaidImageRenderer.render(
            source: MessagePart.nativeMermaidSource(src),
            theme: theme,
            scale: 2.0
        ) { result in
            guard renderID == token else { return }
            switch result {
            case .success(let upright):
                if let upright {
                    image = upright
                    useWeb = false
                } else {
                    OverlayLog.write("beautiful-mermaid returned nil, falling back to mermaid.js")
                    useWeb = true
                }
            case .failure(let error):
                OverlayLog.write("beautiful-mermaid failed: \(error.localizedDescription)")
                useWeb = true
            }
        }
    }
}

struct MermaidWKView: NSViewRepresentable {
    var source: String
    @Binding var height: CGFloat
    @Binding var failed: Bool
    var interactive: Bool = false
    var maxHeight: CGFloat = 2400
    var opaqueBackground = false

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(source: source, height: $height, failed: $failed)
        coordinator.maxHeight = maxHeight
        return coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "mermaidReady")
        let webView = MermaidWebView(frame: .zero, configuration: config)
        webView.setValue(opaqueBackground, forKey: "drawsBackground")
        webView.underPageBackgroundColor = opaqueBackground ? .white : .clear
        webView.allowsMagnification = interactive
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        if let dir = MermaidResources.directory {
            webView.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        } else {
            DispatchQueue.main.async { failed = true }
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.failed = $failed
        context.coordinator.maxHeight = maxHeight
        context.coordinator.setSource(source)
        context.coordinator.relayoutIfNeeded(width: webView.bounds.width)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "mermaidReady")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var source: String
        var height: Binding<CGFloat>
        var failed: Binding<Bool>
        var maxHeight: CGFloat = 2400
        weak var webView: WKWebView?
        private var ready = false
        private var applied = ""
        private var lastWidth: CGFloat = 0

        init(source: String, height: Binding<CGFloat>, failed: Binding<Bool>) {
            self.source = source
            self.height = height
            self.failed = failed
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            inject()
        }

        func setSource(_ next: String) {
            source = next
            if ready {
                inject()
            }
        }

        func relayoutIfNeeded(width: CGFloat) {
            guard ready, width > 1, abs(width - lastWidth) > 8 else { return }
            lastWidth = width
            applied = ""
            inject()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "mermaidReady" else { return }
            let body = message.body as? [String: Any] ?? [:]
            if body["ready"] as? Bool == true {
                inject()
                return
            }
            let ok = body["ok"] as? Bool ?? false
            DispatchQueue.main.async {
                if ok {
                    let drawn = CGFloat((body["height"] as? NSNumber)?.doubleValue ?? 0)
                    if drawn > 1 {
                        self.height.wrappedValue = min(self.maxHeight, max(72, drawn.rounded() + 8))
                    }
                    self.failed.wrappedValue = false
                    self.webView?.evaluateJavaScript("window.scrollTo(0,0)")
                } else {
                    OverlayLog.write("mermaid.js render failed: \(body["error"] ?? "")")
                    self.failed.wrappedValue = true
                }
            }
        }

        private func inject() {
            guard ready, applied != source else { return }
            applied = source
            let b64 = Data(source.utf8).base64EncodedString()
            webView?.evaluateJavaScript("window.fxRenderB64 && window.fxRenderB64('\(b64)')")
        }
    }
}

private final class MermaidWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        if allowsMagnification {
            super.scrollWheel(with: event)
            return
        }
        enclosingScrollView?.scrollWheel(with: event)
            ?? nextResponder?.scrollWheel(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        evaluateJavaScript("window.scrollTo(0,0)")
    }
}

enum MermaidImageFix {
    static func upright(_ image: NSImage) -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let size = image.size
        let flipped = NSImage(size: size)
        flipped.lockFocus()
        defer { flipped.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(origin: .zero, size: size))
        return flipped
    }
}

enum MermaidImageRenderer {
    private static let queue = DispatchQueue(
        label: "local.bubble.mermaid-render",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )

    static func render(
        source: String,
        theme: DiagramTheme,
        scale: CGFloat,
        completion: @escaping (Result<NSImage?, Error>) -> Void
    ) {
        queue.async {
            let result: Result<NSImage?, Error>
            do {
                let image = try MermaidRenderer.renderImage(source: source, theme: theme, scale: scale)
                result = .success(image.map(MermaidImageFix.upright))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}

enum MermaidResources {
    static var directory: URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let candidates = [
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Mermaid")?
                .deletingLastPathComponent(),
            exe.deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/Mermaid"),
            exe.deletingLastPathComponent().appendingPathComponent("Mermaid"),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("mermaid.min.js").path)
        }
    }
}
