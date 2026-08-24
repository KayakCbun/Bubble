import Foundation

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

enum InlineRun: Equatable {
    case text(String)
    case strong(String)
    case chip(String, PathChipKind)

    func replacingText(with text: String) -> InlineRun {
        switch self {
        case .text:
            return .text(text)
        case .strong:
            return .strong(text)
        case .chip:
            return self
        }
    }
}

enum MarkdownEmphasis {
    struct Span: Equatable {
        var inner: String
        var remainder: String
    }

    struct Boundaries: Equatable {
        var leading: String
        var core: String
        var trailing: String
    }

    static func boundaries(in text: String) -> Boundaries {
        let leading = text.prefix { $0.isWhitespace }
        let withoutLeading = text.dropFirst(leading.count)
        let trailing = withoutLeading.reversed().prefix { $0.isWhitespace }
        let core = withoutLeading.dropLast(trailing.count)
        return Boundaries(
            leading: String(leading),
            core: String(core),
            trailing: String(trailing.reversed())
        )
    }

    static func runs(for text: String) -> [InlineRun] {
        let parts = boundaries(in: text)
        guard !parts.core.isEmpty else { return [.text("**" + text + "**")] }
        var runs: [InlineRun] = []
        if !parts.leading.isEmpty { runs.append(.text(parts.leading)) }
        runs.append(.strong(parts.core))
        if !parts.trailing.isEmpty { runs.append(.text(parts.trailing)) }
        return runs
    }

    static func consumeLeading(in text: String) -> Span? {
        guard text.hasPrefix("**") else { return nil }
        let body = String(text.dropFirst(2))
        guard let end = body.range(of: "**") else { return nil }
        return Span(
            inner: String(body[..<end.lowerBound]),
            remainder: String(body[end.upperBound...])
        )
    }
}

enum CodeToken {
    static func looksLike(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if leading(text) == text { return true }
        if text.hasPrefix("<"), text.hasSuffix(">"), text.count <= 80 { return true }
        if isBracketTag(text) { return true }
        return false
    }

    static func leading(_ text: String) -> String? {
        guard let first = text.first else { return nil }
        if first == "<" { return leadingTag(text) }
        if first == "[" { return leadingBracketTag(text) }
        if text.hasPrefix("ou_") || text.hasPrefix("oc_") {
            return leadingPrefixedID(text)
        }
        if first == "/" { return leadingSlashCommand(text) }
        if isASCIILetter(first) { return leadingIdent(text) }
        if first.isNumber { return leadingNumber(text) }
        return nil
    }

    static func nextRange(in text: String) -> Range<String.Index>? {
        var index = text.startIndex
        var previous: Character = "\n"
        while index < text.endIndex {
            if isBoundary(previous) {
                let rest = String(text[index...])
                if let token = leading(rest) {
                    return index..<text.index(index, offsetBy: token.count)
                }
            }
            previous = text[index]
            index = text.index(after: index)
        }
        return nil
    }

    static func isBoundary(_ character: Character) -> Bool {
        if character.isWhitespace || character.isNewline { return true }
        if character == "`" || character == "*" { return true }
        if isCJK(character) { return true }
        return "，。、；：！？,.!?;:()（）[]【】{}<>《》\"“”‘’/\\|#=+~".contains(character)
    }

    private static func leadingTag(_ text: String) -> String? {
        guard text.first == "<" else { return nil }
        var end = text.index(after: text.startIndex)
        var count = 1
        while end < text.endIndex, count < 80 {
            let ch = text[end]
            if ch == "\n" { return nil }
            if ch == ">" {
                return String(text[text.startIndex...end])
            }
            end = text.index(after: end)
            count += 1
        }
        return nil
    }

    private static func isBracketTag(_ text: String) -> Bool {
        guard text.hasPrefix("["), text.hasSuffix("]"), text.count <= 24 else { return false }
        let inner = text.dropFirst().dropLast()
        guard inner.count >= 2 else { return false }
        if inner.contains(where: isCJK) { return true }
        return inner.range(of: "[A-Z]{2,}", options: .regularExpression) != nil
    }

    private static func leadingBracketTag(_ text: String) -> String? {
        guard text.first == "[" else { return nil }
        var end = text.index(after: text.startIndex)
        var count = 1
        while end < text.endIndex, count < 24 {
            let ch = text[end]
            if ch == "\n" { return nil }
            if ch == "]" {
                let token = String(text[text.startIndex...end])
                return isBracketTag(token) ? token : nil
            }
            end = text.index(after: end)
            count += 1
        }
        return nil
    }

    private static func leadingPrefixedID(_ text: String) -> String? {
        var end = text.startIndex
        var seenUnderscore = false
        while end < text.endIndex {
            let ch = text[end]
            if ch == "_" {
                seenUnderscore = true
                end = text.index(after: end)
                continue
            }
            if isASCIILetter(ch) || ch.isNumber {
                end = text.index(after: end)
                continue
            }
            break
        }
        let token = String(text[text.startIndex..<end])
        guard seenUnderscore, token.count >= 4 else { return nil }
        return token
    }

    private static func leadingSlashCommand(_ text: String) -> String? {
        guard text.first == "/" else { return nil }
        var end = text.index(after: text.startIndex)
        guard end < text.endIndex, isASCIILetter(text[end]) else { return nil }
        while end < text.endIndex {
            let ch = text[end]
            if isASCIILetter(ch) || ch.isNumber || ch == "_" || ch == "-" {
                end = text.index(after: end)
                continue
            }
            break
        }
        let token = String(text[text.startIndex..<end])
        return token.count >= 3 && token.count <= 24 ? token : nil
    }

    private static func leadingIdent(_ text: String) -> String? {
        var end = text.startIndex
        var underscores = 0
        var dots = 0
        while end < text.endIndex {
            let ch = text[end]
            if isASCIILetter(ch) || ch.isNumber {
                end = text.index(after: end)
                continue
            }
            if ch == "_" {
                underscores += 1
                end = text.index(after: end)
                continue
            }
            if ch == "." {
                let next = text.index(after: end)
                guard next < text.endIndex, isASCIILetter(text[next]) else { break }
                dots += 1
                end = next
                continue
            }
            break
        }
        let token = String(text[text.startIndex..<end])
        if underscores >= 1, dots == 0, token.count >= 3 { return token }
        if dots >= 2, token.count >= 5 { return token }
        return nil
    }

    private static func leadingNumber(_ text: String) -> String? {
        var end = text.startIndex
        while end < text.endIndex, text[end].isNumber {
            end = text.index(after: end)
        }
        let token = String(text[text.startIndex..<end])
        guard token.count >= 6 else { return nil }
        if end < text.endIndex, text[end] == "/" { return nil }
        return token
    }

    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }
}

enum ProseWrap {
    static let cannotStartLine = CharacterSet(charactersIn: "，。、；：！？,.!?;:）)]》」』、%％°")

    static func cannotStart(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { cannotStartLine.contains($0) }
    }

    static func isGlueRun(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return trimmed.allSatisfy(cannotStart)
    }

    static func glue(_ head: String, tail: String) -> (String, String) {
        var head = head
        var tail = tail
        while let first = tail.first, cannotStart(first) {
            head.append(first)
            tail.removeFirst()
        }
        while tail.first?.isWhitespace == true {
            tail.removeFirst()
        }
        return (head, tail)
    }
}

enum ProseReflow {
    private static let headingSuffixes = [
        "现象", "链路", "方案", "原因", "结论", "现状", "背景", "步骤",
        "分析", "概述", "总结", "进展", "状态", "说明", "建议", "处理",
        "排查", "问题", "清单", "结果", "详情", "摘要", "要点", "注意",
    ]

    static func reflow(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var out = ""
        var index = text.startIndex
        var lineStart = true

        func ensureBlankLine() {
            while out.hasSuffix("*") {
                out.removeLast()
            }
            while out.hasSuffix(" ") {
                out.removeLast()
            }
            if out.isEmpty || out.hasSuffix("\n\n") { return }
            if out.hasSuffix("\n") {
                out.append("\n")
            } else {
                out.append("\n\n")
            }
        }

        func ensureNewline() {
            while out.hasSuffix("*") {
                out.removeLast()
            }
            while out.hasSuffix(" ") {
                out.removeLast()
            }
            if out.isEmpty || out.hasSuffix("\n") { return }
            out.append("\n")
        }

        while index < text.endIndex {
            if text[index] == "`" {
                let (span, next) = consumeCodeSpan(text, from: index)
                out.append(span)
                index = next
                lineStart = false
                continue
            }
            if text[index] == "\n" {
                out.append("\n")
                index = text.index(after: index)
                lineStart = true
                continue
            }

            if lineStart, let table = consumePipeTable(text, from: index) {
                out.append(table.markup)
                index = table.next
                lineStart = true
                continue
            }

            if let heading = matchHeading(text, from: index) {
                if !lineStart { ensureBlankLine() }
                out.append(heading.markup)
                out.append("\n\n")
                index = heading.next
                lineStart = true
                continue
            }

            if let numbered = matchNumbered(text, from: index, lineStart: lineStart) {
                if !lineStart { ensureBlankLine() }
                out.append(numbered.markup)
                index = numbered.next
                lineStart = false
                continue
            }

            if let bullet = matchBullet(text, from: index, lineStart: lineStart) {
                if !lineStart { ensureNewline() }
                out.append(bullet.markup)
                index = bullet.next
                lineStart = false
                continue
            }

            if let rule = matchRule(text, from: index, lineStart: lineStart) {
                if !lineStart { ensureBlankLine() }
                out.append("---\n\n")
                index = rule
                lineStart = true
                continue
            }

            if let conclusion = matchConclusion(text, from: index, lineStart: lineStart) {
                ensureBlankLine()
                out.append(conclusion.markup)
                index = conclusion.next
                lineStart = false
                continue
            }

            out.append(text[index])
            lineStart = false
            index = text.index(after: index)
        }

        return out
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func consumeCodeSpan(_ text: String, from start: String.Index) -> (String, String.Index) {
        var fence = 0
        var index = start
        while index < text.endIndex, text[index] == "`" {
            fence += 1
            index = text.index(after: index)
        }
        let marker = String(repeating: "`", count: max(1, fence))
        if let end = text[index...].range(of: marker) {
            return (String(text[start..<end.upperBound]), end.upperBound)
        }
        return (String(text[start...]), text.endIndex)
    }

    private struct Piece {
        var markup: String
        var next: String.Index
    }

    private static func matchHeading(_ text: String, from start: String.Index) -> Piece? {
        if let prev = prevCharacter(text, before: start),
           !prev.isWhitespace, !prev.isNewline, !isBreakBoundary(prev) {
            return nil
        }
        guard text[start] == "#" else { return nil }
        var index = start
        var level = 0
        while index < text.endIndex, text[index] == "#", level < 6 {
            level += 1
            index = text.index(after: index)
        }
        guard level > 0, index < text.endIndex else { return nil }
        let next = text[index]
        guard next.isWhitespace || next.isLetter || CodeToken.isCJK(next) else { return nil }
        while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        let (title, bodyStart) = headingTitle(text, from: index)
        guard !title.isEmpty else { return nil }
        return Piece(markup: String(repeating: "#", count: level) + " " + title, next: bodyStart)
    }

    private static func headingTitle(_ text: String, from start: String.Index) -> (String, String.Index) {
        let rest = String(text[start...])
        if let structure = firstNearbyStructure(rest) {
            let title = String(rest[..<structure]).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty {
                return (title, text.index(start, offsetBy: rest.distance(from: rest.startIndex, to: structure)))
            }
        }
        if let paren = rest.range(of: #"^\p{Han}{2,12}[（(][^）)]{1,24}[）)]"#, options: .regularExpression) {
            let title = String(rest[paren])
            let after = String(rest[paren.upperBound...])
            if after.count >= 4 || firstNearbyStructure(after) != nil {
                return (title, text.index(start, offsetBy: rest.distance(from: rest.startIndex, to: paren.upperBound)))
            }
        }
        let prefix = String(rest.prefix(20))
        var best: String.Index?
        for suffix in headingSuffixes {
            if let range = prefix.range(of: suffix) {
                if best == nil || range.upperBound > best! {
                    best = range.upperBound
                }
            }
        }
        if let best, prefix.distance(from: prefix.startIndex, to: best) <= 16 {
            let title = String(prefix[prefix.startIndex..<best])
            let body = String(rest[best...])
            if body.count >= 6 {
                return (title, text.index(start, offsetBy: rest.distance(from: rest.startIndex, to: best)))
            }
        }
        var end = start
        var count = 0
        while end < text.endIndex, count < 24 {
            let ch = text[end]
            if ch == "\n" || ch == "#" { break }
            if ch == "。" || ch == "！" || ch == "？" { break }
            end = text.index(after: end)
            count += 1
        }
        let title = String(text[start..<end]).trimmingCharacters(in: .whitespaces)
        return (title, end)
    }

    private static func firstNearbyStructure(_ text: String) -> String.Index? {
        let window = String(text.prefix(36))
        if let numbered = window.range(of: #"\d{1,2}\.\s"#, options: .regularExpression) {
            if window.distance(from: window.startIndex, to: numbered.lowerBound) <= 24 {
                let prefix = window[..<numbered.lowerBound]
                if prefix.hasSuffix("**") {
                    return window.index(numbered.lowerBound, offsetBy: -2)
                }
                return numbered.lowerBound
            }
        }
        if let heading = window.range(of: "##") {
            if window.distance(from: window.startIndex, to: heading.lowerBound) <= 24 {
                return heading.lowerBound
            }
        }
        if let bullet = window.range(of: #"-(?:\s+|\p{Han}|\*\*)"#, options: .regularExpression) {
            if window.distance(from: window.startIndex, to: bullet.lowerBound) <= 24 {
                return bullet.lowerBound
            }
        }
        return nil
    }

    private static func matchNumbered(_ text: String, from start: String.Index, lineStart: Bool) -> Piece? {
        var index = start
        let boldTitle = peek(text, from: start, count: 2) == "**"
        if boldTitle {
            index = text.index(index, offsetBy: 2)
        } else if text[index] == "*" {
            while index < text.endIndex, text[index] == "*" {
                index = text.index(after: index)
            }
        }
        var digits = ""
        var cursor = index
        while cursor < text.endIndex, text[cursor].isNumber, digits.count < 2 {
            digits.append(text[cursor])
            cursor = text.index(after: cursor)
        }
        guard !digits.isEmpty, cursor < text.endIndex, text[cursor] == "." else { return nil }
        let afterDot = text.index(after: cursor)
        guard afterDot < text.endIndex else { return nil }
        let next = text[afterDot]
        guard next == " " || next == "*" || CodeToken.isCJK(next) || next.isLetter else { return nil }
        if !lineStart {
            if let prev = prevCharacter(text, before: start), !isBreakBoundary(prev) {
                return nil
            }
        }
        var consumed = afterDot
        if consumed < text.endIndex, text[consumed] == " " {
            consumed = text.index(after: consumed)
        }
        return Piece(markup: "\(digits). \(boldTitle ? "**" : "")", next: consumed)
    }

    private static func matchBullet(_ text: String, from start: String.Index, lineStart: Bool) -> Piece? {
        guard text[start] == "-" || text[start] == "*" else { return nil }
        if text[start] == "*" {
            if peek(text, from: start, count: 2).hasPrefix("**") { return nil }
            let after = text.index(after: start)
            guard after < text.endIndex, text[after] == " " else { return nil }
            if !lineStart, let prev = prevCharacter(text, before: start), prev == "*" || !isBreakBoundary(prev) {
                return nil
            }
            return Piece(markup: "- ", next: text.index(after: after))
        }
        let after = text.index(after: start)
        guard after < text.endIndex else { return nil }
        let next = text[after]
        let gluedHan = CodeToken.isCJK(next)
        let spaced = next == " " || next == "*"
        guard gluedHan || spaced else { return nil }
        if !lineStart {
            if let prev = prevCharacter(text, before: start) {
                let allowed = isBreakBoundary(prev) || CodeToken.isCJK(prev)
                if !allowed { return nil }
                var lookahead = after
                while lookahead < text.endIndex, text[lookahead] == " " {
                    lookahead = text.index(after: lookahead)
                }
                let afterSpaces = lookahead < text.endIndex ? text[lookahead] : " "
                if CodeToken.isCJK(prev), !gluedHan, afterSpaces != "*" { return nil }
            }
        }
        var consumed = after
        if consumed < text.endIndex, text[consumed] == " " {
            consumed = text.index(after: consumed)
        }
        return Piece(markup: "- ", next: consumed)
    }

    private static func consumePipeTable(_ text: String, from start: String.Index) -> Piece? {
        var cursor = start
        while cursor < text.endIndex, text[cursor] == " " || text[cursor] == "\t" {
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex, text[cursor] == "|" else { return nil }
        var index = start
        while index < text.endIndex {
            let lineStart = index
            while index < text.endIndex, text[index] == " " || text[index] == "\t" {
                index = text.index(after: index)
            }
            if index >= text.endIndex || text[index] != "|" {
                index = lineStart
                break
            }
            while index < text.endIndex, text[index] != "\n" {
                index = text.index(after: index)
            }
            if index < text.endIndex {
                index = text.index(after: index)
            }
        }
        let block = String(text[start..<index])
        guard block.contains("|") else { return nil }
        return Piece(markup: block, next: index)
    }

    private static func matchRule(_ text: String, from start: String.Index, lineStart: Bool) -> String.Index? {
        guard peek(text, from: start, count: 3) == "---" else { return nil }
        if !lineStart, let prev = prevCharacter(text, before: start), !isBreakBoundary(prev) {
            return nil
        }
        if let prev = prevNonSpace(text, before: start), prev == "|" {
            return nil
        }
        var index = text.index(start, offsetBy: 3)
        while index < text.endIndex, text[index] == "-" {
            index = text.index(after: index)
        }
        return index
    }

    private static func prevNonSpace(_ text: String, before index: String.Index) -> Character? {
        var i = index
        while i > text.startIndex {
            i = text.index(before: i)
            if text[i] != " " && text[i] != "\t" {
                return text[i]
            }
        }
        return nil
    }

    private static func matchConclusion(_ text: String, from start: String.Index, lineStart: Bool) -> Piece? {
        guard !lineStart else { return nil }
        let phrases = ["所以根因", "所以结论", "综上", "需要我帮你", "要继续往下"]
        for phrase in phrases {
            if peek(text, from: start, count: phrase.count) == phrase {
                if let prev = prevCharacter(text, before: start), prev.isNewline { return nil }
                return Piece(markup: phrase, next: text.index(start, offsetBy: phrase.count))
            }
        }
        return nil
    }

    private static func prevCharacter(_ text: String, before index: String.Index) -> Character? {
        guard index > text.startIndex else { return nil }
        return text[text.index(before: index)]
    }

    private static func isBreakBoundary(_ character: Character) -> Bool {
        if character.isWhitespace || character.isNewline { return true }
        return "，。、；：！？,.!?;:）)]》」』\"”’`".contains(character)
    }

    private static func peek(_ text: String, from start: String.Index, count: Int) -> String {
        let end = text.index(start, offsetBy: count, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end])
    }
}
