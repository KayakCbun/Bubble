import Foundation

enum PaletteKind: String {
    case command
    case skill
    case template
    case file
    case model
    case thinking
    case app
    case clipboard
    case mount
}

struct PaletteItem: Identifiable, Equatable {
    var kind: PaletteKind
    var title: String
    var subtitle: String
    var insert: String
    var hint: String? = nil
    var autoSend: Bool = false
    var artworkPath: String? = nil
    var badge: String? = nil
    var role: String? = nil

    var id: String { "\(kind.rawValue):\(insert):\(title):\(role ?? "")" }
}

struct PaletteToken: Equatable {
    enum Trigger: Equatable {
        case slash(query: String)
        case mention(query: String)
        case skill(query: String)

        var query: String {
            switch self {
            case .slash(let query), .mention(let query), .skill(let query):
                return query
            }
        }

        var caption: String {
            switch self {
            case .slash: "Commands"
            case .mention: "Files"
            case .skill: "Skills"
            }
        }

        var signature: String {
            switch self {
            case .slash(let query): "slash:\(query)"
            case .mention(let query): "at:\(query)"
            case .skill(let query): "skill:\(query)"
            }
        }
    }

    var trigger: Trigger
    var range: Range<String.Index>
}

enum PromptPalette {
    static func activeToken(in draft: String) -> PaletteToken? {
        guard let last = lastTokenRange(in: draft) else { return nil }
        let token = String(draft[last])
        if token.hasPrefix("/") {
            return PaletteToken(trigger: .slash(query: String(token.dropFirst())), range: last)
        }
        if token.hasPrefix("@") {
            return PaletteToken(trigger: .mention(query: String(token.dropFirst())), range: last)
        }
        if token.hasPrefix("$") {
            return PaletteToken(trigger: .skill(query: String(token.dropFirst())), range: last)
        }
        return nil
    }

    static func replaceToken(in draft: String, with insert: String) -> String {
        guard let token = activeToken(in: draft) else { return insert }
        return String(draft[..<token.range.lowerBound]) + insert
    }

    static func matches(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        let q = query.lowercased()
        if q.isEmpty { return items }
        let prefixed = items.filter { item in
            item.title.lowercased().hasPrefix(q)
                || searchableName(item.title).lowercased().hasPrefix(q)
        }
        if !prefixed.isEmpty { return prefixed }
        return items.filter { item in
            let title = item.title.lowercased()
            let name = searchableName(item.title).lowercased()
            return title.contains(q)
                || name.contains(q)
                || item.subtitle.lowercased().contains(q)
        }
    }

    static func matchesFiles(_ files: [WorkspaceFile], query: String) -> [WorkspaceFile] {
        let q = query.lowercased()
        if q.isEmpty {
            return Array(files.prefix(40))
        }
        let ranked: [(Int, WorkspaceFile)] = files.compactMap { file in
            let path = file.displayPath.lowercased()
            let name = file.name.lowercased()
            if name.hasPrefix(q) { return (0, file) }
            if path.hasPrefix(q) { return (1, file) }
            if name.contains(q) { return (2, file) }
            if path.contains(q) { return (3, file) }
            return nil
        }
        return ranked
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                if lhs.1.displayPath.count != rhs.1.displayPath.count {
                    return lhs.1.displayPath.count < rhs.1.displayPath.count
                }
                return lhs.1.displayPath < rhs.1.displayPath
            }
            .map(\.1)
    }

    private static func searchableName(_ title: String) -> String {
        var value = title
        if value.hasPrefix("/") || value.hasPrefix("@") || value.hasPrefix("$") {
            value = String(value.dropFirst())
        }
        if let colon = value.firstIndex(of: ":") {
            return String(value[value.index(after: colon)...])
        }
        if let slash = value.lastIndex(of: "/") {
            return String(value[value.index(after: slash)...])
        }
        return value
    }

    private static func lastTokenRange(in draft: String) -> Range<String.Index>? {
        if draft.isEmpty { return nil }
        if draft.last?.isWhitespace == true { return nil }
        let whitespace = CharacterSet.whitespacesAndNewlines
        var index = draft.endIndex
        while index > draft.startIndex {
            let previous = draft.index(before: index)
            let scalar = draft[previous].unicodeScalars.first
            if let scalar, whitespace.contains(scalar) {
                break
            }
            index = previous
        }
        if index == draft.endIndex { return nil }
        return index..<draft.endIndex
    }
}
