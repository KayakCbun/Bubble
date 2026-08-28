import AppKit
import SwiftUI

private struct BubbleTextSelectionModifier: ViewModifier {
    @Environment(\.bubbleTextSelectionEnabled) private var enabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}

private struct BubbleTextSelectionEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var bubbleTextSelectionEnabled: Bool {
        get { self[BubbleTextSelectionEnabledKey.self] }
        set { self[BubbleTextSelectionEnabledKey.self] = newValue }
    }
}

extension View {
    func bubbleTextSelection() -> some View {
        modifier(BubbleTextSelectionModifier())
    }
}

struct PathChipIcon: Equatable {
    var symbol: String
    var color: Color
    var markdown: Bool = false
}

struct MarkdownFileGlyph: View {
    var pointSize: CGFloat = 12

    static let fill = Color(red: 0.22, green: 0.52, blue: 0.96)

    var body: some View {
        let width = pointSize * 0.90
        let height = pointSize
        ZStack {
            MarkdownPageShape()
                .fill(Self.fill)
            MarkdownPageShape.fold()
                .fill(Color.white.opacity(0.28))
            Text("MD")
                .font(.system(size: max(5.5, pointSize * 0.36), weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
                .tracking(-0.3)
                .offset(y: pointSize * 0.08)
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

private struct MarkdownPageShape: Shape {
    func path(in rect: CGRect) -> Path {
        Self.page(in: rect)
    }

    static func fold() -> some Shape {
        MarkdownPageFold()
    }

    static func page(in rect: CGRect) -> Path {
        let fold = min(rect.width, rect.height) * 0.30
        let radius = min(1.8, rect.width * 0.16)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private struct MarkdownPageFold: Shape {
    func path(in rect: CGRect) -> Path {
        let fold = min(rect.width, rect.height) * 0.30
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY + fold))
        path.closeSubpath()
        return path
    }
}

enum PathChipStyle {
    static func classify(_ raw: String) -> PathChipKind {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
            || lowered.hasPrefix("file://") || lowered.hasPrefix("www.") {
            return .url
        }
        if isPath(text) {
            let last = (text as NSString).lastPathComponent
            if text.hasSuffix("/") || !last.contains(".") {
                return .folder
            }
            let ext = (last as NSString).pathExtension.lowercased()
            return ext.isEmpty ? .folder : .file(ext)
        }
        if let ext = fileExtension(in: text) {
            return .file(ext)
        }
        return .code
    }

    static func icon(for kind: PathChipKind) -> PathChipIcon? {
        switch kind {
        case .code:
            return nil
        case .url:
            return PathChipIcon(symbol: "globe", color: Color(red: 0.18, green: 0.52, blue: 0.96))
        case .folder:
            return PathChipIcon(symbol: "folder.fill", color: Color(red: 0.20, green: 0.62, blue: 0.98))
        case .file(let ext):
            return fileIcon(ext)
        }
    }

    static func fileIcon(_ ext: String) -> PathChipIcon {
        switch ext {
        case "md", "markdown":
            return PathChipIcon(
                symbol: "doc",
                color: MarkdownFileGlyph.fill,
                markdown: true
            )
        case "txt", "rtf":
            return PathChipIcon(symbol: "doc.text", color: Color(red: 0.42, green: 0.48, blue: 0.58))
        case "swift":
            return PathChipIcon(symbol: "swift", color: Color(red: 0.95, green: 0.45, blue: 0.18))
        case "json", "yml", "yaml", "toml", "xml", "plist":
            return PathChipIcon(symbol: "curlybraces", color: Color(red: 0.82, green: 0.62, blue: 0.16))
        case "js", "ts", "jsx", "tsx", "mjs":
            return PathChipIcon(symbol: "chevron.left.forwardslash.chevron.right", color: Color(red: 0.92, green: 0.72, blue: 0.16))
        case "html", "htm", "css":
            return PathChipIcon(symbol: "chevron.left.forwardslash.chevron.right", color: Color(red: 0.90, green: 0.42, blue: 0.18))
        case "py":
            return PathChipIcon(symbol: "doc.fill", color: Color(red: 0.22, green: 0.48, blue: 0.82))
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic":
            return PathChipIcon(symbol: "photo.fill", color: Color(red: 0.62, green: 0.38, blue: 0.92))
        case "pdf":
            return PathChipIcon(symbol: "doc.fill", color: Color(red: 0.86, green: 0.22, blue: 0.22))
        case "mp4", "mov", "webm":
            return PathChipIcon(symbol: "film.fill", color: Color(red: 0.55, green: 0.35, blue: 0.90))
        case "sh", "zsh", "bash":
            return PathChipIcon(symbol: "terminal.fill", color: Color(red: 0.25, green: 0.68, blue: 0.42))
        default:
            return PathChipIcon(symbol: "doc.fill", color: Color(red: 0.55, green: 0.58, blue: 0.62))
        }
    }

    static func isPath(_ text: String) -> Bool {
        if text.hasPrefix("~/") || text == "~" { return true }
        if text.hasPrefix("./") || text.hasPrefix("../") { return true }
        let roots = ["/Users/", "/home/", "/opt/", "/usr/", "/var/", "/tmp/", "/etc/", "/Applications/", "/Volumes/", "/Library/"]
        if roots.contains(where: { text.hasPrefix($0) }) { return true }
        if text.hasPrefix("/") {
            if roots.contains(where: { text.hasPrefix($0) }) { return true }
            return text.split(separator: "/").count >= 3
        }
        return false
    }

    static func fileExtension(in text: String) -> String? {
        let last = (text as NSString).lastPathComponent
        guard last != text || last.contains(".") else { return nil }
        let ext = (last as NSString).pathExtension.lowercased()
        let known: Set<String> = PreviewFiles.supportedExtensions.union([
            "swift", "yml", "yaml", "ts", "js", "tsx", "jsx",
            "py", "rb", "go", "rs", "html", "css", "pdf", "png", "jpg", "jpeg", "gif", "svg",
            "sh", "zsh", "toml", "xml", "plist", "mp4", "mov",
        ])
        return known.contains(ext) ? ext : nil
    }

    static func needsClassicMarkdown(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") { return true }
        if trimmed.hasPrefix("|"), trimmed.contains("\n|") { return true }
        return false
    }
}

enum ProseBlock: Equatable {
    case heading(Int, [InlineRun])
    case paragraph([InlineRun])
    case bullet([InlineRun])
    case numbered(Int, [InlineRun])
    case rule
}

enum ProseParser {
    static func blocks(in text: String, completed: Bool = true) -> [ProseBlock] {
        guard completed else { return parseBlocks(in: text) }
        return ProseBlockCache.shared.blocks(for: text) {
            parseBlocks(in: text)
        }
    }

    private static func parseBlocks(in text: String) -> [ProseBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [ProseBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = joinParagraph(paragraph)
            if !joined.isEmpty {
                blocks.append(.paragraph(tokenize(joined)))
            }
            paragraph.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix("#") {
                flushParagraph()
                var level = 0
                var rest = trimmed
                while rest.hasPrefix("#") && level < 6 {
                    rest.removeFirst()
                    level += 1
                }
                rest = rest.trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(max(1, level), tokenize(rest)))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(tokenize(String(trimmed.dropFirst(2)))))
                continue
            }
            if let numbered = numberedItem(trimmed) {
                flushParagraph()
                blocks.append(.numbered(numbered.index, tokenize(numbered.body)))
                continue
            }
            paragraph.append(trimmed)
        }
        flushParagraph()
        return blocks
    }

    static func tokenize(_ text: String) -> [InlineRun] {
        var runs: [InlineRun] = []
        var remaining = text
        while !remaining.isEmpty {
            if let span = leadingCodeSpan(remaining) {
                remaining.removeFirst(span.consumed)
                if !span.code.isEmpty {
                    runs.append(.chip(span.code, PathChipStyle.classify(span.code)))
                }
                continue
            }
            if remaining.hasPrefix("**") {
                if let span = MarkdownEmphasis.consumeLeading(in: remaining) {
                    remaining = span.remainder
                    emitEmphasis(span.inner, into: &runs)
                    continue
                }
                remaining.removeFirst(2)
                runs.append(.text("**"))
                continue
            }
            if let link = leadingMarkdownLink(remaining) {
                remaining.removeFirst(link.consumed)
                let target = PreviewFiles.trimTrailingPunctuation(link.url)
                let lowered = target.lowercased()
                if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("www.") {
                    runs.append(.chip(target, .url))
                } else {
                    runs.append(.chip(target, PathChipStyle.classify(target)))
                }
                continue
            }
            if let url = leadingURL(remaining) {
                remaining.removeFirst(url.count)
                let trimmed = url.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]}>"))
                let tail = String(url.dropFirst(trimmed.count))
                runs.append(.chip(trimmed, .url))
                if !tail.isEmpty { remaining = tail + remaining }
                continue
            }
            if let path = leadingPath(remaining) {
                remaining.removeFirst(path.count)
                runs.append(.chip(path, PathChipStyle.classify(path)))
                continue
            }
            if let relative = leadingRelativeFile(remaining) {
                remaining.removeFirst(relative.count)
                runs.append(.chip(relative, PathChipStyle.classify(relative)))
                continue
            }
            if let token = CodeToken.leading(remaining) {
                remaining.removeFirst(token.count)
                runs.append(.chip(token, PathChipStyle.classify(token)))
                continue
            }
            var next = remaining.endIndex
            if let tick = remaining.firstIndex(of: "`") { next = min(next, tick) }
            if let bold = remaining.range(of: "**")?.lowerBound { next = min(next, bold) }
            if let link = remaining.range(of: "](")?.lowerBound {
                if let open = remaining[..<link].lastIndex(of: "[") {
                    next = min(next, open)
                }
            }
            if let http = remaining.range(of: "http://")?.lowerBound { next = min(next, http) }
            if let https = remaining.range(of: "https://")?.lowerBound { next = min(next, https) }
            if let file = remaining.range(of: "file://")?.lowerBound { next = min(next, file) }
            if let home = remaining.range(of: "~/")?.lowerBound { next = min(next, home) }
            if let relative = nextRelativeFile(in: remaining) { next = min(next, relative.lowerBound) }
            if let code = CodeToken.nextRange(in: remaining) { next = min(next, code.lowerBound) }
            if next == remaining.startIndex {
                runs.append(.text(String(remaining.prefix(1))))
                remaining.removeFirst()
            } else {
                runs.append(.text(String(remaining[..<next])))
                remaining = String(remaining[next...])
            }
        }
        return mergeText(runs)
    }

    private static func isRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t == "***" || (t.count >= 3 && t.allSatisfy { $0 == "-" })
    }

    private static func leadingCodeSpan(_ text: String) -> (code: String, consumed: Int)? {
        guard text.first == "`" else { return nil }
        var fence = 0
        var index = text.startIndex
        while index < text.endIndex, text[index] == "`" {
            fence += 1
            index = text.index(after: index)
        }
        let marker = String(repeating: "`", count: fence)
        guard let end = text[index...].range(of: marker) else { return nil }
        let code = String(text[index..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
        let consumed = text.distance(from: text.startIndex, to: end.upperBound)
        return (code, consumed)
    }

    private static func emitEmphasis(_ inner: String, into runs: inout [InlineRun]) {
        let parts = MarkdownEmphasis.boundaries(in: inner)
        guard !parts.core.isEmpty else {
            runs.append(.text("**" + inner + "**"))
            return
        }
        if CodeToken.looksLike(parts.core) {
            if !parts.leading.isEmpty { runs.append(.text(parts.leading)) }
            runs.append(.chip(parts.core, PathChipStyle.classify(parts.core)))
            if !parts.trailing.isEmpty { runs.append(.text(parts.trailing)) }
            return
        }
        let innerRuns = tokenize(parts.core)
        let hasChip = innerRuns.contains { if case .chip = $0 { return true }; return false }
        guard hasChip else {
            runs.append(contentsOf: MarkdownEmphasis.runs(for: inner))
            return
        }
        if !parts.leading.isEmpty { runs.append(.text(parts.leading)) }
        for run in innerRuns {
            switch run {
            case .chip:
                runs.append(run)
            case .text(let text):
                appendBoldText(text, into: &runs)
            case .strong(let text):
                appendBoldText(text, into: &runs)
            }
        }
        if !parts.trailing.isEmpty {
            runs.append(.text(parts.trailing))
        }
    }

    private static func appendBoldText(_ text: String, into runs: inout [InlineRun]) {
        guard !text.isEmpty else { return }
        let lead = text.prefix { $0.isWhitespace }
        let trail = text.reversed().prefix { $0.isWhitespace }
        let coreStart = lead.count
        let coreEnd = text.count - trail.count
        if coreStart >= coreEnd {
            runs.append(.text(text))
            return
        }
        if !lead.isEmpty {
            runs.append(.text(String(lead)))
        }
        let core = String(text[text.index(text.startIndex, offsetBy: coreStart)..<text.index(text.startIndex, offsetBy: coreEnd)])
        runs.append(.strong(core))
        if !trail.isEmpty {
            runs.append(.text(String(trail.reversed())))
        }
    }

    private static func leadingMarkdownLink(_ text: String) -> (label: String, url: String, consumed: Int)? {
        var offset = 0
        var body = text
        if body.hasPrefix("!") {
            body.removeFirst()
            offset = 1
        }
        guard body.hasPrefix("["), let close = body.firstIndex(of: "]") else { return nil }
        let label = String(body[body.index(after: body.startIndex)..<close])
        let afterClose = body.index(after: close)
        guard afterClose < body.endIndex, body[afterClose] == "(" else { return nil }
        let urlStart = body.index(after: afterClose)
        guard let end = body[urlStart...].firstIndex(of: ")") else { return nil }
        let url = String(body[urlStart..<end]).trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return nil }
        let consumed = offset + body.distance(from: body.startIndex, to: body.index(after: end))
        return (label, url, consumed)
    }

    /// Soft-wrap lines inside a paragraph. Markdown treats consecutive lines as
    /// one paragraph; keeping `\n` would make SwiftUI wrap under the previous chip.
    private static func joinParagraph(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            let piece = line.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            if result.isEmpty {
                result = piece
                continue
            }
            if paragraphJoinNeedsSpace(result, piece) {
                result += " " + piece
            } else {
                result += piece
            }
        }
        return result
    }

    private static func paragraphJoinNeedsSpace(_ left: String, _ right: String) -> Bool {
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

    private static func mergeText(_ runs: [InlineRun]) -> [InlineRun] {
        var merged: [InlineRun] = []
        for run in runs {
            if case .text(let text) = run, case .text(let last) = merged.last {
                merged[merged.count - 1] = .text(last + text)
            } else if case .strong(let text) = run, case .strong(let last) = merged.last {
                merged[merged.count - 1] = .strong(last + text)
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    private static func numberedItem(_ line: String) -> (index: Int, body: String)? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let number = line[..<dot]
        guard let value = Int(number), value >= 0 else { return nil }
        let after = line.index(after: dot)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return (value, String(line[line.index(after: after)...]))
    }

    private static func leadingURL(_ text: String) -> String? {
        let prefixes = ["https://", "http://", "file://"]
        guard prefixes.contains(where: { text.lowercased().hasPrefix($0) }) else { return nil }
        var end = text.startIndex
        for index in text.indices {
            let ch = text[index]
            if ch.isWhitespace || "，。、）)>]".contains(ch) { break }
            end = text.index(after: index)
        }
        let value = String(text[text.startIndex..<end])
        return value.isEmpty ? nil : value
    }

    private static func leadingPath(_ text: String) -> String? {
        if text.hasPrefix("~/") || text.hasPrefix("./") || text.hasPrefix("../") || PathChipStyle.isPath(String(text.prefix(16))) {
            var end = text.startIndex
            var started = false
            for index in text.indices {
                let ch = text[index]
                if !started {
                    started = true
                    end = text.index(after: index)
                    continue
                }
                if ch.isWhitespace || "，。、）)>]`".contains(ch) { break }
                end = text.index(after: index)
            }
            let value = PreviewFiles.trimTrailingPunctuation(String(text[text.startIndex..<end]))
            return PathChipStyle.isPath(value) || PathChipStyle.fileExtension(in: value) != nil ? value : nil
        }
        return nil
    }

    private static func leadingRelativeFile(_ text: String) -> String? {
        guard let first = text.first else { return nil }
        if first == "/" || first == "~" { return nil }
        guard first.isLetter || first == "." else { return nil }
        var end = text.startIndex
        var slashes = 0
        for index in text.indices {
            let ch = text[index]
            if ch.isWhitespace || "，。、）)>]`\"'".contains(ch) { break }
            if ch == "/" { slashes += 1 }
            end = text.index(after: index)
        }
        guard slashes >= 1 else { return nil }
        let value = PreviewFiles.trimTrailingPunctuation(String(text[text.startIndex..<end]))
        guard PathChipStyle.fileExtension(in: value) != nil else { return nil }
        let lowered = value.lowercased()
        if lowered.hasPrefix("http:") || lowered.hasPrefix("https:") { return nil }
        return value
    }

    private static func nextRelativeFile(in text: String) -> Range<String.Index>? {
        var index = text.startIndex
        var previous: Character = "\n"
        while index < text.endIndex {
            if previous.isWhitespace || previous.isNewline || CodeToken.isBoundary(previous) {
                let rest = String(text[index...])
                if let token = leadingRelativeFile(rest) {
                    return index..<text.index(index, offsetBy: token.count)
                }
            }
            previous = text[index]
            index = text.index(after: index)
        }
        return nil
    }
}

private final class ProseBlockBox {
    let blocks: [ProseBlock]

    init(_ blocks: [ProseBlock]) {
        self.blocks = blocks
    }
}

/// Lazy transcript rows are discarded while scrolling and can be constructed
/// again when they re-enter the viewport. Keep the semantic parse separate
/// from the SwiftUI view lifetime so revisiting a long answer stays cheap.
private final class ProseBlockCache {
    static let shared = ProseBlockCache()

    private let cache: NSCache<NSString, ProseBlockBox> = {
        let cache = NSCache<NSString, ProseBlockBox>()
        cache.countLimit = 256
        cache.totalCostLimit = 12 * 1_024 * 1_024
        return cache
    }()

    func blocks(for text: String, build: () -> [ProseBlock]) -> [ProseBlock] {
        let key = text as NSString
        if let cached = cache.object(forKey: key) {
            return cached.blocks
        }
        let blocks = build()
        cache.setObject(ProseBlockBox(blocks), forKey: key, cost: text.utf8.count)
        return blocks
    }
}

struct WorkspaceTranscriptWarmupItem: Sendable {
    var identity: String
    var text: String
}

enum WorkspaceTranscriptWarmup {
    static func prepare(_ items: [WorkspaceTranscriptWarmupItem]) {
        for item in items {
            guard !Task.isCancelled else { return }
            guard WorkspaceTranscriptChunker.isParagraphLocal(item.text) else { continue }
            let visibleEdges = WorkspaceTranscriptChunker.visibleEdges(
                item.text,
                identity: item.identity
            )
            for chunk in visibleEdges {
                guard !Task.isCancelled else { return }
                _ = ProseParser.blocks(in: chunk)
            }
        }
    }
}

private enum ProseTypography {
    static let themeVersion = 1
    static let layoutVersion = 2

    static func fingerprint(fontSize: CGFloat, weight: Double) -> ProseTypographyFingerprint {
        ProseTypographyFingerprint(
            fontSize: Double(fontSize),
            weight: weight,
            lineSpacing: Double(OverlaySurface.proseLineSpacing),
            theme: themeVersion,
            displayScale: Double(NSScreen.main?.backingScaleFactor ?? 2),
            layoutVersion: layoutVersion
        )
    }

    static var body: ProseTypographyFingerprint {
        fingerprint(fontSize: OverlayMetrics.fontSize, weight: 400)
    }

    static func heading(level: Int) -> ProseTypographyFingerprint {
        let size = level <= 1 ? OverlayMetrics.heading1Size : level == 2 ? OverlayMetrics.heading2Size : OverlayMetrics.heading3Size
        return fingerprint(fontSize: size, weight: 600)
    }
}

struct ProseDocument: View {
    var text: String
    var streaming: Bool = false

    var body: some View {
        let completed = !streaming
        VStack(alignment: .leading, spacing: OverlaySurface.proseBlockSpacing) {
            ForEach(Array(ProseParser.blocks(in: text, completed: completed).enumerated()), id: \.offset) { _, block in
                switch block {
                    case .heading(let level, let runs):
                        inlineFlow(
                            runs,
                            font: .system(
                                size: level <= 1 ? OverlayMetrics.heading1Size : level == 2 ? OverlayMetrics.heading2Size : OverlayMetrics.heading3Size,
                                weight: .semibold
                            ),
                            typography: ProseTypography.heading(level: level),
                            completed: completed
                        )
                    .padding(.top, level <= 2 ? 20 : 16)
                    .padding(.bottom, 8)
                case .paragraph(let runs):
                    inlineFlow(runs, typography: ProseTypography.body, completed: completed)
                case .rule:
                    Divider()
                        .opacity(0.28)
                        .padding(.vertical, 6)
                case .bullet(let runs):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        inlineFlow(runs, typography: ProseTypography.body, completed: completed)
                    }
                case .numbered(let index, let runs):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index).")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        inlineFlow(runs, typography: ProseTypography.body, completed: completed)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func inlineFlow(
        _ runs: [InlineRun],
        font: Font = OverlayMetrics.bodyFont,
        typography: ProseTypographyFingerprint = ProseTypography.body,
        completed: Bool
    ) -> some View {
        if InlineRun.usesNativeTextLayout(runs) {
            let key = ProseRenderKey(runs: runs, width: 0, typography: typography)
            let prepared = ProseRenderCache.shared.preparedInline(for: key, completed: completed) {
                ProsePreparedInline(
                    runs: runs,
                    attributedString: Self.semanticNativeAttributedText(runs, font: font)
                )
            }
            Text(Self.styledNativeAttributedText(prepared))
                .font(font)
                .foregroundStyle(OverlaySurface.conversationInk)
                .lineSpacing(OverlaySurface.proseLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .bubbleTextSelection()
        } else {
            FlowWidthReader { width in
                let sourceKey = ProseRenderKey(runs: runs, width: Double(width), typography: typography)
                let prepared = ProseRenderCache.shared.preparedInline(for: sourceKey, completed: completed) {
                    ProsePreparedInline(runs: runs)
                }
                let wrappedKey = ProseRenderKey(
                    content: sourceKey.content,
                    width: Double(width),
                    typography: typography,
                    variant: 1
                )
                let wrapped = ProseRenderCache.shared.preparedInline(for: wrappedKey, completed: completed) {
                    ProsePreparedInline(runs: Self.breakRuns(prepared.runs, width: width))
                }
                FlowLayout(
                    horizontalSpacing: 5,
                    verticalSpacing: OverlaySurface.proseLineSpacing,
                    renderKey: wrappedKey,
                    completed: completed
                ) {
                    ForEach(Array(wrapped.runs.enumerated()), id: \.offset) { _, run in
                        switch run {
                        case .text(let text):
                            Text(Self.cachedInlineMarkdown(text, typography: typography, completed: completed))
                                .font(font)
                                .foregroundStyle(OverlaySurface.conversationInk)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: true)
                                .bubbleTextSelection()
                        case .strong(let text):
                            Text(Self.cachedInlineMarkdown(text, typography: typography, completed: completed))
                                .font(font)
                                .fontWeight(.semibold)
                                .foregroundStyle(OverlaySurface.conversationInk)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: true)
                                .bubbleTextSelection()
                        case .chip(let text, let kind):
                            InlineChip(text: text, kind: kind)
                        }
                    }
                }
            }
        }
    }

    private static func semanticNativeAttributedText(_ runs: [InlineRun], font: Font) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            let text: String
            switch run {
            case .text(let value), .strong(let value), .chip(let value, _):
                text = value
            }
            var part = AttributedString(text)
            switch run {
            case .text:
                break
            case .strong:
                part.font = font.weight(.semibold)
            case .chip(_, .code):
                part.font = .system(size: OverlayMetrics.chipSize, weight: .regular, design: .monospaced)
            case .chip:
                break
            }
            result.append(part)
        }
        return result
    }

    private static func styledNativeAttributedText(_ prepared: ProsePreparedInline) -> AttributedString {
        var result = prepared.attributedString
        var index = result.startIndex
        for run in prepared.runs {
            let text: String
            switch run {
            case .text(let value), .strong(let value), .chip(let value, _):
                text = value
            }
            guard !text.isEmpty else { continue }
            var end = index
            for _ in 0..<text.count {
                guard end < result.endIndex else { break }
                end = result.index(afterCharacter: end)
            }
            guard end > index else { continue }
            let range = index..<end
            result[range].foregroundColor = OverlaySurface.conversationInk
            if case .chip(_, .code) = run {
                result[range].backgroundColor = OverlaySurface.chipFill
            }
            index = end
        }
        return result
    }

    private static func breakRuns(_ runs: [InlineRun], width: CGFloat) -> [InlineRun] {
        guard width > 48 else { return runs }
        let font = NSFont.systemFont(ofSize: OverlayMetrics.fontSize, weight: .regular)
        let chipFont = NSFont.monospacedSystemFont(ofSize: OverlayMetrics.chipSize, weight: .regular)
        let spacing: CGFloat = 5
        var result: [InlineRun] = []
        var x: CGFloat = 0

        func widthOf(_ string: String, font: NSFont) -> CGFloat {
            ceil(NSAttributedString(string: string, attributes: [.font: font]).size().width)
        }

        func chipWidth(_ text: String, kind: PathChipKind) -> CGFloat {
            let icon: CGFloat = PathChipStyle.icon(for: kind) == nil ? 0 : 15
            return min(width, 14 + icon + widthOf(text, font: chipFont))
        }

        for run in runs {
            switch run {
            case .chip(let text, let kind):
                let w = chipWidth(text, kind: kind)
                if x > 0, x + w > width {
                    x = 0
                }
                result.append(run)
                x += w + spacing
                if x >= width { x = 0 }
            case .text(let raw), .strong(let raw):
                let segments = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                for (index, segment) in segments.enumerated() {
                    if index > 0 { x = 0 }
                    var remainingText = String(segment)
                    while !remainingText.isEmpty {
                        let glueOnly = ProseWrap.isGlueRun(remainingText)
                        if x > 0, width - x < 36, !glueOnly {
                            x = 0
                        }
                        let available = x <= 0 ? width : max(glueOnly ? 8 : 36, width - x)
                        let (head, tail) = fitPrefix(remainingText, maxWidth: available, font: font)
                        if head.isEmpty {
                            if x > 0 {
                                x = 0
                                continue
                            }
                            result.append(run.replacingText(with: remainingText))
                            x = 0
                            break
                        }
                        result.append(run.replacingText(with: head))
                        if tail.isEmpty {
                            x += widthOf(head, font: font) + spacing
                            if x >= width { x = 0 }
                            break
                        }
                        remainingText = tail
                        x = 0
                    }
                }
            }
        }
        return result
    }

    private static func fitPrefix(_ string: String, maxWidth: CGFloat, font: NSFont) -> (String, String) {
        func measure(_ value: String) -> CGFloat {
            ceil(NSAttributedString(string: value, attributes: [.font: font]).size().width)
        }
        // SwiftUI Text is often a few points wider than NSAttributedString.
        let budget = max(24, maxWidth - 8)
        if measure(string) <= budget { return (string, "") }
        if budget < 24 { return ("", string) }

        var low = 0
        var high = string.count
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            let index = string.index(string.startIndex, offsetBy: mid)
            if measure(String(string[..<index])) <= budget {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard best > 0 else { return ("", string) }
        var cut = string.index(string.startIndex, offsetBy: best)
        let prefix = String(string[..<cut])
        if let breakAt = prefix.lastIndex(where: { $0.isWhitespace || "，。、；：,.;:".contains($0) }) {
            let distance = prefix.distance(from: prefix.startIndex, to: breakAt)
            if distance >= max(4, best / 3) {
                cut = prefix.index(after: breakAt)
            }
        }
        while cut > string.startIndex {
            let previous = string.index(before: cut)
            if ProseWrap.cannotStart(string[previous]), previous > string.startIndex {
                cut = previous
                continue
            }
            break
        }
        let glued = ProseWrap.glue(String(string[..<cut]), tail: String(string[cut...]))
        return glued
    }

    private static func cachedInlineMarkdown(
        _ text: String,
        typography: ProseTypographyFingerprint,
        completed: Bool
    ) -> AttributedString {
        let key = ProseRenderKey(text: text, width: 0, typography: typography, variant: 2)
        return ProseRenderCache.shared.preparedInline(for: key, completed: completed) {
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            let attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
            return ProsePreparedInline(runs: [.text(text)], attributedString: attributed)
        }.attributedString
    }
}

struct InlineChip: View {
    var text: String
    var kind: PathChipKind
    @Environment(\.openFilePreview) private var openFilePreview
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: OverlaySurface.chipRadius, style: .continuous)
        let icon = PathChipStyle.icon(for: kind)
        let label = HStack(spacing: 4) {
            if kind.isFilePath {
                PierreFileIcon(path: displayText, size: 11)
            } else if let icon {
                Image(systemName: icon.symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(icon.color)
            }
            Text(displayText)
                .font(.system(size: OverlayMetrics.chipSize, weight: .regular, design: kind.isMonospaced ? .monospaced : .default))
                .foregroundStyle(kind == .url ? Color(red: 0.16, green: 0.42, blue: 0.90) : OverlaySurface.conversationInk)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, icon == nil ? 7 : 5)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .background(
            shape.fill(hovering && isActionable ? OverlaySurface.userFill : OverlaySurface.chipFill)
        )
        .overlay {
            shape.stroke(
                hovering && isActionable ? OverlaySurface.chipStroke.opacity(1.4) : OverlaySurface.chipStroke,
                lineWidth: 0.5
            )
        }
        .contentShape(shape)
        .textSelection(.disabled)

        return Group {
            if isActionable {
                Button(action: openIfPossible) { label }
                    .buttonStyle(.plain)
                    .help(helpText)
            } else {
                label
            }
        }
        .onHover { isHovering in
            hovering = isHovering
            guard isActionable else { return }
            if isHovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    private var isActionable: Bool {
        switch kind {
        case .file, .folder, .url: return true
        case .code: return false
        }
    }

    private var helpText: String {
        switch kind {
        case .file(let ext) where PreviewFiles.isPreviewable(ext: ext):
            return "Preview file"
        case .file, .folder:
            return "Show in Finder"
        case .url:
            return "Open"
        case .code:
            return ""
        }
    }

    private var displayText: String {
        if case .url = kind, let url = URL(string: text), let host = url.host {
            let path = url.path
            if path.isEmpty || path == "/" { return host }
            return host + path
        }
        if text.hasPrefix("/"), text.count > 36 {
            return (text as NSString).lastPathComponent
        }
        return text
    }

    private func openIfPossible() {
        switch kind {
        case .url:
            var raw = text
            if raw.lowercased().hasPrefix("www.") { raw = "https://" + raw }
            if raw.lowercased().hasPrefix("file://"),
               PreviewFiles.isPreviewable(path: PreviewFiles.stripFileURL(raw)) {
                openFilePreview?(raw)
                return
            }
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
            }
        case .file(let ext):
            if PreviewFiles.isPreviewable(ext: ext), let openFilePreview {
                openFilePreview(text)
                return
            }
            revealInFinder()
        case .folder:
            revealInFinder()
        case .code:
            break
        }
    }

    private func revealInFinder() {
        let path = (text as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

private struct OpenFilePreviewKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var openFilePreview: ((String) -> Void)? {
        get { self[OpenFilePreviewKey.self] }
        set { self[OpenFilePreviewKey.self] = newValue }
    }
}

private struct FlowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FlowWidthReader<Content: View>: View {
    @ViewBuilder var content: (CGFloat) -> Content
    @State private var width: CGFloat = OverlayMetrics.transcriptWidthDefault - OverlayMetrics.transcriptInset * 2

    var body: some View {
        content(width)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: FlowWidthKey.self, value: proxy.size.width)
                }
            }
            .onPreferenceChange(FlowWidthKey.self) { width = $0 }
    }
}

struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 5
    var verticalSpacing: CGFloat = OverlaySurface.proseLineSpacing
    var renderKey: ProseRenderKey?
    var completed: Bool = true

    struct Cache {
        var width: CGFloat?
        var subviewCount = 0
        var result: (size: CGSize, frames: [CGRect])?
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        cachedArrangement(proposal: proposal, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let result = cachedArrangement(
            proposal: ProposedViewSize(width: bounds.width, height: nil),
            subviews: subviews,
            cache: &cache
        )
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(
                at: CGPoint(
                    x: OverlayPixel.align(bounds.minX + frame.minX, scale: 2),
                    y: OverlayPixel.align(bounds.minY + frame.minY, scale: 2)
                ),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func cachedArrangement(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> (size: CGSize, frames: [CGRect]) {
        let width = proposal.width
        if cache.width == width,
           cache.subviewCount == subviews.count,
           let result = cache.result {
            return result
        }
        let result: (size: CGSize, frames: [CGRect])
        if let renderKey,
           let width,
           width.isFinite,
           width > 0 {
            let measuredKey = ProseRenderKey(
                content: renderKey.content,
                width: Double(width),
                typography: renderKey.typography,
                variant: renderKey.variant + 2
            )
            let measured = ProseRenderCache.shared.measuredLayout(for: measuredKey, completed: completed) {
                let arranged = arrange(proposal: proposal, subviews: subviews)
                return ProseMeasuredLayout(
                    width: Double(arranged.size.width),
                    height: Double(arranged.size.height),
                    lineCount: arranged.frames.count,
                    frames: arranged.frames
                )
            }
            if measured.frames.count == subviews.count {
                result = (
                    CGSize(width: measured.width, height: measured.height),
                    measured.frames
                )
            } else {
                result = arrange(proposal: proposal, subviews: subviews)
            }
        } else {
            result = arrange(proposal: proposal, subviews: subviews)
        }
        cache.width = width
        cache.subviewCount = subviews.count
        cache.result = result
        return result
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        let multiline = OverlayMetrics.fontSize * 3.2
        for subview in subviews {
            let natural = subview.sizeThatFits(ProposedViewSize(width: .infinity, height: nil))
            if x > 0, maxWidth.isFinite {
                let remaining = maxWidth - x
                let tooWide = natural.width > remaining + 0.5
                let tooTall = natural.height > multiline
                if tooWide || tooTall {
                    y += lineHeight + verticalSpacing
                    x = 0
                    lineHeight = 0
                }
            }
            var size: CGSize
            if x == 0, maxWidth.isFinite, natural.width > maxWidth + 0.5 || natural.height > multiline {
                size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            } else {
                size = natural
            }
            if maxWidth.isFinite {
                size.width = min(size.width, maxWidth)
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            lineHeight = max(lineHeight, size.height)
            x += size.width + horizontalSpacing
            usedWidth = max(usedWidth, x - horizontalSpacing)
            if maxWidth.isFinite, x >= maxWidth {
                y += lineHeight + verticalSpacing
                x = 0
                lineHeight = 0
            }
        }

        let width = maxWidth.isFinite ? maxWidth : usedWidth
        return (CGSize(width: width, height: y + lineHeight), frames)
    }
}
