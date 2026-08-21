import AppKit
import SwiftUI

enum PathChipKind: Equatable {
    case code
    case file(String)
    case folder
    case url

    var isMonospaced: Bool {
        switch self {
        case .code, .file, .folder: return true
        case .url: return false
        }
    }
}

struct PathChipIcon: Equatable {
    var symbol: String
    var color: Color
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
        case "md", "markdown", "txt", "rtf":
            return PathChipIcon(symbol: "doc.richtext.fill", color: Color(red: 0.25, green: 0.55, blue: 0.95))
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
        let known: Set<String> = [
            "md", "markdown", "txt", "swift", "json", "yml", "yaml", "ts", "js", "tsx", "jsx",
            "py", "rb", "go", "rs", "html", "css", "pdf", "png", "jpg", "jpeg", "gif", "svg",
            "sh", "zsh", "toml", "xml", "plist", "mp4", "mov",
        ]
        return known.contains(ext) ? ext : nil
    }

    static func needsClassicMarkdown(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") { return true }
        if trimmed.hasPrefix("|"), trimmed.contains("\n|") { return true }
        return false
    }
}

enum InlineRun: Equatable {
    case text(String)
    case chip(String, PathChipKind)
}

enum ProseBlock: Equatable {
    case heading(Int, [InlineRun])
    case paragraph([InlineRun])
    case bullet([InlineRun])
    case numbered(Int, [InlineRun])
    case rule
}

enum ProseParser {
    static func blocks(in text: String) -> [ProseBlock] {
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
                remaining.removeFirst(2)
                if let end = remaining.range(of: "**") {
                    let inner = String(remaining[..<end.lowerBound])
                    remaining = String(remaining[end.upperBound...])
                    emitEmphasis(inner, into: &runs)
                    continue
                }
                runs.append(.text("**"))
                continue
            }
            if let link = leadingMarkdownLink(remaining) {
                remaining.removeFirst(link.consumed)
                let target = MarkdownFiles.trimTrailingPunctuation(link.url)
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
        if inner.isEmpty { return }
        if CodeToken.looksLike(inner) {
            runs.append(.chip(inner, PathChipStyle.classify(inner)))
            return
        }
        let innerRuns = tokenize(inner)
        let hasChip = innerRuns.contains { if case .chip = $0 { return true }; return false }
        guard hasChip else {
            runs.append(.text("**" + inner + "**"))
            return
        }
        for run in innerRuns {
            switch run {
            case .chip:
                runs.append(run)
            case .text(let text):
                appendBoldText(text, into: &runs)
            }
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
        runs.append(.text("**" + core + "**"))
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
            let value = MarkdownFiles.trimTrailingPunctuation(String(text[text.startIndex..<end]))
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
        let value = MarkdownFiles.trimTrailingPunctuation(String(text[text.startIndex..<end]))
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

struct ProseDocument: View {
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ProseParser.blocks(in: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let runs):
                    inlineFlow(
                        runs,
                        font: .system(
                            size: level <= 1 ? OverlayMetrics.heading1Size : level == 2 ? OverlayMetrics.heading2Size : OverlayMetrics.heading3Size,
                            weight: .medium
                        )
                    )
                    .padding(.top, level <= 2 ? 8 : 4)
                    .padding(.bottom, 1)
                case .paragraph(let runs):
                    inlineFlow(runs)
                case .rule:
                    Divider()
                        .opacity(0.28)
                        .padding(.vertical, 6)
                case .bullet(let runs):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        inlineFlow(runs)
                    }
                case .numbered(let index, let runs):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index).")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        inlineFlow(runs)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineFlow(_ runs: [InlineRun], font: Font = OverlayMetrics.bodyFont) -> some View {
        FlowWidthReader { width in
            FlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
                ForEach(Array(Self.breakRuns(runs, width: width).enumerated()), id: \.offset) { _, run in
                    switch run {
                    case .text(let text):
                        Text(inlineMarkdown(text))
                            .font(font)
                            .foregroundStyle(OverlayMetrics.ink)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: true)
                            .textSelection(.enabled)
                    case .chip(let text, let kind):
                        InlineChip(text: text, kind: kind)
                    }
                }
            }
        }
    }

    private static func breakRuns(_ runs: [InlineRun], width: CGFloat) -> [InlineRun] {
        guard width > 48 else { return runs }
        let font = NSFont.systemFont(ofSize: OverlayMetrics.fontSize)
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
            case .text(let raw):
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
                            result.append(.text(remainingText))
                            x = 0
                            break
                        }
                        result.append(.text(head))
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

    private func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct InlineChip: View {
    var text: String
    var kind: PathChipKind
    @Environment(\.openMarkdownPreview) private var openMarkdownPreview
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let icon = PathChipStyle.icon(for: kind)
        let label = HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon.symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(icon.color)
            }
            Text(displayText)
                .font(.system(size: OverlayMetrics.chipSize, weight: .regular, design: kind.isMonospaced ? .monospaced : .default))
                .foregroundStyle(kind == .url ? Color(red: 0.16, green: 0.42, blue: 0.90) : OverlayMetrics.ink.opacity(hovering && isActionable ? 0.95 : 0.82))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, icon == nil ? 6 : 5)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .background(
            shape.fill(Color.primary.opacity(hovering && isActionable ? 0.12 : 0.06))
        )
        .overlay {
            shape.stroke(Color.primary.opacity(hovering && isActionable ? 0.22 : 0), lineWidth: 1)
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
        case .file(let ext) where MarkdownFiles.isMarkdown(ext: ext):
            return "Preview markdown"
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
            if raw.lowercased().hasPrefix("file://"), MarkdownFiles.isMarkdown(path: MarkdownFiles.stripFileURL(raw)) {
                openMarkdownPreview?(raw)
                return
            }
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
            }
        case .file(let ext):
            if MarkdownFiles.isMarkdown(ext: ext), let openMarkdownPreview {
                openMarkdownPreview(text)
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

private struct OpenMarkdownPreviewKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var openMarkdownPreview: ((String) -> Void)? {
        get { self[OpenMarkdownPreviewKey.self] }
        set { self[OpenMarkdownPreviewKey.self] = newValue }
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
    var verticalSpacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height),
            subviews: subviews
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
