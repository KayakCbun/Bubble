import Foundation

public enum MermaidSource {
    public static func normalize(_ raw: String) -> String {
        raw
            .components(separatedBy: .newlines)
            .flatMap(splitStatements)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitStatements(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var index = line.startIndex
        var squareDepth = 0
        var curlyDepth = 0
        var parenDepth = 0
        var quoted = false

        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                quoted.toggle()
                current.append(character)
                index = line.index(after: index)
                continue
            }
            if !quoted {
                switch character {
                case "[": squareDepth += 1
                case "]": squareDepth = max(0, squareDepth - 1)
                case "{": curlyDepth += 1
                case "}": curlyDepth = max(0, curlyDepth - 1)
                case "(": parenDepth += 1
                case ")": parenDepth = max(0, parenDepth - 1)
                default: break
                }
            }
            let atTopLevel = !quoted && squareDepth == 0 && curlyDepth == 0 && parenDepth == 0
            guard atTopLevel, character.isWhitespace, character != "\n", character != "\r" else {
                current.append(character)
                index = line.index(after: index)
                continue
            }

            let whitespaceStart = index
            while index < line.endIndex, line[index].isWhitespace {
                index = line.index(after: index)
            }
            let whitespace = line[whitespaceStart..<index]
            let next = String(line[index...]).trimmingCharacters(in: .whitespaces)
            let previous = current.trimmingCharacters(in: .whitespaces)
            if isStatementBoundary(previous: previous, next: next, whitespaceCount: whitespace.count) {
                if !previous.isEmpty { parts.append(previous) }
                current = ""
            } else if !current.isEmpty {
                current.append(" ")
            }
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { parts.append(tail) }
        return parts
    }

    private static func isStatementBoundary(
        previous: String,
        next: String,
        whitespaceCount: Int
    ) -> Bool {
        guard !previous.isEmpty, !next.isEmpty else { return false }
        let lowerNext = next.lowercased()
        if lowerNext == "end" || lowerNext.hasPrefix("end ") { return true }
        if lowerNext.hasPrefix("subgraph ") {
            return isDiagramHeader(previous) || previous.lowercased() == "end"
        }
        if previous.lowercased() == "end" { return true }
        if let last = previous.last, "]})".contains(last), looksLikeNodeDeclaration(next) {
            return true
        }
        if whitespaceCount >= 2, containsArrow(previous), looksLikeStatementStart(next) {
            return true
        }
        return false
    }

    private static func isDiagramHeader(_ text: String) -> Bool {
        text.range(
            of: #"^(?:flowchart|graph)\s+(?:TB|TD|BT|LR|RL)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func looksLikeNodeDeclaration(_ text: String) -> Bool {
        text.range(
            of: #"^[A-Za-z_][A-Za-z0-9_-]*\s*[\[\{\(]"#,
            options: .regularExpression
        ) != nil
    }

    private static func looksLikeStatementStart(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.hasPrefix("subgraph ") || lower == "end" || lower.hasPrefix("end ") {
            return true
        }
        return looksLikeNodeDeclaration(text)
            || text.range(
                of: #"^[A-Za-z_][A-Za-z0-9_-]*\s*(?:-->|---|==>|-\.->)"#,
                options: .regularExpression
            ) != nil
    }

    private static func containsArrow(_ text: String) -> Bool {
        ["-->", "---", "==>", "-.->"].contains { text.contains($0) }
    }
}
