import Foundation

enum FileChangeKind: String, Equatable {
    case create
    case edit
    case delete
}

struct FileChange: Equatable, Identifiable {
    var path: String
    var additions: Int?
    var deletions: Int?
    var kind: FileChangeKind
    var oldText: String?
    var newText: String?

    var id: String { path }

    var fileName: String {
        (path as NSString).lastPathComponent
    }

    var folder: String {
        let dir = (path as NSString).deletingLastPathComponent
        if dir.isEmpty || dir == "." || dir == "/" { return "" }
        return dir
    }

    var hasLineStats: Bool {
        (additions ?? 0) > 0 || (deletions ?? 0) > 0
    }
}

struct FileChangeGroup: Equatable, Identifiable {
    var folder: String
    var files: [FileChange]
    var id: String { folder }

    var additions: Int? { FileChangeSummaryPolicy.total(files.map(\.additions)) }
    var deletions: Int? { FileChangeSummaryPolicy.total(files.map(\.deletions)) }
    var hasLineStats: Bool { files.contains(where: \.hasLineStats) }
}

struct FileChangeSummary: Equatable, Identifiable {
    var id: String
    var files: [FileChange]
    var workspaceRoot: String? = nil

    var additions: Int? { FileChangeSummaryPolicy.total(files.map(\.additions)) }
    var deletions: Int? { FileChangeSummaryPolicy.total(files.map(\.deletions)) }
    var hasLineStats: Bool { files.contains(where: \.hasLineStats) }
    var groups: [FileChangeGroup] {
        FileChangeSummaryPolicy.groups(from: files)
    }
}

enum FileChangeCardPolicy {
    static let expandsByDefault = false

    static func isExpanded(id: String, expandedIDs: Set<String>) -> Bool {
        expandedIDs.contains(id)
    }

    /// Path-only mentions have no diff. The card only lists files whose
    /// additions or deletions were counted from old/new text or a patch.
    static func belongsInChangedFiles(_ file: FileChange) -> Bool {
        file.hasLineStats
    }
}

enum FileChangeSummaryPolicy {
    static func isFileMutation(kind: String?, title: String) -> Bool {
        let k = (kind ?? "").lowercased()
        if ["edit", "write", "delete", "move", "create", "patch"].contains(k) {
            return true
        }
        let t = title.lowercased()
        let prefixes = ["edit ", "write ", "create ", "delete ", "remove ", "update ", "patch "]
        return prefixes.contains(where: { t.hasPrefix($0) })
            || t.contains(" edited")
            || looksLikeDiff(title)
    }

    static func looksLikeDiff(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return text.hasPrefix("diff ") || text.contains("\n---\n")
    }

    static func change(kind: String?, title: String, input: String?, output: String?) -> FileChange? {
        if let parsed = parseDiff(output) { return parsed }
        if let parsed = parseUnified(output) { return parsed }
        if let parsed = parseJSONEdit(input) { return parsed }
        if let parsed = parseJSONEdit(output) { return parsed }
        guard isFileMutation(kind: kind, title: title) || looksLikeDiff(output) else {
            return nil
        }
        if let path = path(fromTitle: title) ?? path(fromTitle: input ?? "") {
            let counts = parseCountHint(output) ?? parseCountHint(title)
            return FileChange(
                path: relativize(path),
                additions: counts?.additions,
                deletions: counts?.deletions,
                kind: kindHint(kind, title: title)
            )
        }
        return nil
    }

    private static var summaryCache: [String: (stamp: String, summary: FileChangeSummary?)] = [:]
    private static let summaryCacheLimit = 64

    static func summary(
        id: String,
        tools: [(kind: String?, title: String, input: String?, output: String?)],
        workspaceRoot: String? = nil
    ) -> FileChangeSummary? {
        let stamp = summaryStamp(tools) + "\u{1e}" + (workspaceRoot ?? "")
        if let hit = summaryCache[id], hit.stamp == stamp {
            return hit.summary
        }
        let result = computeSummary(id: id, tools: tools, workspaceRoot: workspaceRoot)
        summaryCache[id] = (stamp, result)
        if summaryCache.count > summaryCacheLimit {
            summaryCache.removeAll(keepingCapacity: true)
            summaryCache[id] = (stamp, result)
        }
        return result
    }

    static func pathHint(
        kind: String? = nil,
        title: String,
        input: String?,
        output: String? = nil,
        workspaceRoot: String? = nil
    ) -> String? {
        if isFileMutation(kind: kind, title: title) {
            return change(
                kind: kind,
                title: title,
                input: input,
                output: output
            ).flatMap { cleanedPath($0.path, workspaceRoot: workspaceRoot) }
        }
        if let parsed = parseJSONEdit(input), parsed.oldText != nil || parsed.newText != nil {
            return cleanedPath(parsed.path, workspaceRoot: workspaceRoot)
        }
        return nil
    }

    static func uniqueDisplayPaths(_ paths: [String], workspaceRoot: String? = nil) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            guard let cleaned = cleanedPath(path, workspaceRoot: workspaceRoot) else { continue }
            if seen.insert(cleaned).inserted {
                result.append(cleaned)
            }
        }
        return result
    }

    static func resolvedPath(
        _ path: String,
        workspaceRoot: String? = nil,
        fallbackRoot: String? = nil
    ) -> String {
        let display = cleanedPath(path, workspaceRoot: workspaceRoot) ?? path.trimmingCharacters(in: .whitespacesAndNewlines)
        if display.hasPrefix("/") {
            return (display as NSString).standardizingPath
        }
        if display.hasPrefix("~/") {
            return NSHomeDirectory() + String(display.dropFirst(1))
        }
        if let root = workspaceRoot ?? fallbackRoot, !root.isEmpty {
            return URL(fileURLWithPath: expandedPath(root), isDirectory: true)
                .appendingPathComponent(display)
                .path
        }
        return display
    }

    static func summaryStamp(_ tools: [(kind: String?, title: String, input: String?, output: String?)]) -> String {
        var parts: [String] = [String(tools.count)]
        parts.reserveCapacity(tools.count * 5 + 1)
        for tool in tools {
            parts.append(tool.kind ?? "")
            parts.append(String(tool.title.count))
            parts.append(String(tool.input?.count ?? 0))
            parts.append(String(tool.output?.count ?? 0))
            if let output = tool.output, output.count > 24 {
                parts.append(String(output.prefix(12)))
                parts.append(String(output.suffix(12)))
            } else {
                parts.append(tool.output ?? "")
            }
        }
        return parts.joined(separator: "\u{1e}")
    }

    private static func computeSummary(
        id: String,
        tools: [(kind: String?, title: String, input: String?, output: String?)],
        workspaceRoot: String?
    ) -> FileChangeSummary? {
        var order: [String] = []
        var byPath: [String: FileChange] = [:]
        for tool in tools {
            guard let next = change(kind: tool.kind, title: tool.title, input: tool.input, output: tool.output) else {
                continue
            }
            var file = next
            if let display = cleanedPath(file.path, workspaceRoot: workspaceRoot) {
                file.path = display
            }
            if byPath[file.path] == nil {
                order.append(file.path)
            }
            if let existing = byPath[file.path] {
                byPath[file.path] = FileChange(
                    path: file.path,
                    additions: file.additions ?? existing.additions,
                    deletions: file.deletions ?? existing.deletions,
                    kind: file.kind == .edit ? existing.kind : file.kind,
                    oldText: file.oldText ?? existing.oldText,
                    newText: file.newText ?? existing.newText
                )
            } else {
                byPath[file.path] = file
            }
        }
        let files = order.compactMap { byPath[$0] }.filter(FileChangeCardPolicy.belongsInChangedFiles)
        guard !files.isEmpty else { return nil }
        return FileChangeSummary(id: id, files: files, workspaceRoot: workspaceRoot)
    }

    static func groups(from files: [FileChange]) -> [FileChangeGroup] {
        var order: [String] = []
        var buckets: [String: [FileChange]] = [:]
        for file in files {
            if buckets[file.folder] == nil {
                order.append(file.folder)
            }
            buckets[file.folder, default: []].append(file)
        }
        return order.map { FileChangeGroup(folder: $0, files: buckets[$0] ?? []) }
    }

    static func total(_ values: [Int?]) -> Int? {
        let known = values.compactMap { $0 }
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +)
    }

    static func lineDelta(old: String, new: String) -> (additions: Int, deletions: Int) {
        if old.isEmpty { return (lineCount(new), 0) }
        if new.isEmpty { return (0, lineCount(old)) }
        let before = old.components(separatedBy: "\n")
        let after = new.components(separatedBy: "\n")
        let diff = after.difference(from: before)
        var additions = 0
        var deletions = 0
        for change in diff {
            switch change {
            case .insert:
                additions += 1
            case .remove:
                deletions += 1
            }
        }
        return (additions, deletions)
    }

    static func unifiedDiff(path: String, old: String?, new: String?) -> String {
        let before = old ?? ""
        let after = new ?? ""
        var lines = ["--- a/\(path)", "+++ b/\(path)"]
        let oldLines = before.components(separatedBy: "\n")
        let newLines = after.components(separatedBy: "\n")
        let diff = newLines.difference(from: oldLines)
        if diff.isEmpty {
            lines.append("@@ unchanged @@")
            return lines.joined(separator: "\n")
        }
        for change in diff {
            switch change {
            case .insert(_, let line, _):
                lines.append("+\(line)")
            case .remove(_, let line, _):
                lines.append("-\(line)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func lineCount(_ text: String) -> Int {
        if text.isEmpty { return 0 }
        return text.components(separatedBy: "\n").count
    }

    static func parseDiff(_ raw: String?) -> FileChange? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("diff ") else { return nil }
        let rest = String(text.dropFirst(5))
        let oldSplit = rest.components(separatedBy: "\n---\n")
        guard oldSplit.count >= 2 else {
            guard let path = diffPath(from: rest) else { return nil }
            return FileChange(path: path, additions: nil, deletions: nil, kind: .edit)
        }
        guard let path = diffPath(from: oldSplit[0]) else { return nil }
        let body = oldSplit[1]
        let parts = body.components(separatedBy: "\n+++\n")
        let oldText = parts[0]
        let newText = parts.count > 1 ? parts[1] : ""
        let delta = lineDelta(old: oldText, new: newText)
        let kind: FileChangeKind
        if oldText.isEmpty && newText.isEmpty {
            return FileChange(path: path, additions: nil, deletions: nil, kind: .edit)
        }
        if oldText.isEmpty { kind = .create }
        else if newText.isEmpty { kind = .delete }
        else { kind = .edit }
        return FileChange(
            path: path,
            additions: delta.additions,
            deletions: delta.deletions,
            kind: kind,
            oldText: oldText,
            newText: newText
        )
    }

    static func parseUnified(_ raw: String?) -> FileChange? {
        guard let raw else { return nil }
        let lines = raw.components(separatedBy: "\n")
        var path: String?
        var additions = 0
        var deletions = 0
        var sawHunk = false
        for line in lines {
            if line.hasPrefix("+++ ") {
                var value = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("b/") { value = String(value.dropFirst(2)) }
                if let cleaned = cleanedPath(value) { path = cleaned }
                continue
            }
            if line.hasPrefix("--- "), path == nil {
                var value = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("a/") { value = String(value.dropFirst(2)) }
                if let cleaned = cleanedPath(value) { path = cleaned }
                continue
            }
            if line.hasPrefix("@@") {
                sawHunk = true
                continue
            }
            guard sawHunk else { continue }
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { additions += 1 }
            else if line.hasPrefix("-") { deletions += 1 }
        }
        guard let path, sawHunk else { return nil }
        return FileChange(
            path: relativize(path),
            additions: additions,
            deletions: deletions,
            kind: additions > 0 && deletions == 0 ? .create : deletions > 0 && additions == 0 ? .delete : .edit
        )
    }

    static func parseCountHint(_ raw: String?) -> (additions: Int, deletions: Int)? {
        guard let raw else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"\+(\d+)\s+[^\d]*\-(\d+)"#) else {
            return nil
        }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range),
              let addRange = Range(match.range(at: 1), in: raw),
              let delRange = Range(match.range(at: 2), in: raw),
              let additions = Int(raw[addRange]),
              let deletions = Int(raw[delRange]) else {
            return nil
        }
        return (additions, deletions)
    }

    static func parseJSONEdit(_ raw: String?) -> FileChange? {
        guard let raw, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return pathFromLooseJSON(raw)
        }
        guard let path = jsonPath(object).flatMap({ cleanedPath($0) }) else { return nil }
        let oldText = jsonString(object, keys: ["oldText", "old_string", "old_content", "original"])
        let newText = jsonString(object, keys: ["newText", "new_string", "new_content", "contents", "content"])
        let jsonAdds = jsonInt(object, keys: ["additions", "added", "insertions"])
        let jsonDels = jsonInt(object, keys: ["deletions", "deleted", "removals"])
        guard oldText != nil || newText != nil || jsonAdds != nil || jsonDels != nil else { return nil }
        let kind: FileChangeKind
        if (oldText ?? "").isEmpty, newText != nil { kind = .create }
        else if newText == nil, !(oldText ?? "").isEmpty { kind = .delete }
        else { kind = .edit }
        let delta = lineDelta(old: oldText ?? "", new: newText ?? oldText ?? "")
        let additions = jsonAdds ?? (oldText == nil && newText == nil ? nil : (kind == .delete ? 0 : delta.additions))
        let deletions = jsonDels ?? (oldText == nil && newText == nil ? nil : (kind == .create ? 0 : delta.deletions))
        return FileChange(
            path: relativize(path),
            additions: additions,
            deletions: deletions,
            kind: kind,
            oldText: oldText,
            newText: newText
        )
    }

    static func path(fromTitle title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["Edit ", "Write ", "Create ", "Delete ", "Remove ", "Update ", "Patch "]
        for prefix in prefixes {
            if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
                let rest = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                guard let token = rest.split(whereSeparator: \.isWhitespace).first else { return nil }
                return cleanedPath(String(token))
            }
        }
        if trimmed.split(whereSeparator: \.isWhitespace).count == 1 {
            return cleanedPath(trimmed)
        }
        return nil
    }

    static func cleanedPath(_ raw: String, workspaceRoot: String? = nil) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let literal = jsonPathLiteral(value) {
            value = literal
        }
        value = unescapePathFragment(value)
        value = stripWrappingQuotes(value)
        value = stripTrailingPathJunk(value)
        value = value.replacingOccurrences(of: "\\", with: "/")
        while value.contains("//") {
            value = value.replacingOccurrences(of: "//", with: "/")
        }
        while value.contains("/./") {
            value = value.replacingOccurrences(of: "/./", with: "/")
        }
        value = relativize(value, workspaceRoot: workspaceRoot)
        guard isPlausibleFilePath(value) else { return nil }
        return value
    }

    static func kindHint(_ kind: String?, title: String) -> FileChangeKind {
        let blob = ((kind ?? "") + " " + title).lowercased()
        if blob.contains("delete") || blob.contains("remove") { return .delete }
        if blob.contains("write") || blob.contains("create") { return .create }
        return .edit
    }

    static func relativize(_ path: String, workspaceRoot: String? = nil) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("file://") {
            value = String(value.dropFirst(7))
        }
        if !value.hasPrefix("/"), !value.hasPrefix("~") {
            return value
        }
        let expanded = expandedPath(value)
        if let workspaceRoot, !workspaceRoot.isEmpty {
            let root = expandedPath(workspaceRoot)
            if expanded == root {
                return (expanded as NSString).lastPathComponent
            }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if expanded.hasPrefix(prefix) {
                return String(expanded.dropFirst(prefix.count))
            }
        }
        let home = NSHomeDirectory()
        if expanded.hasPrefix(home + "/") {
            return "~" + String(expanded.dropFirst(home.count))
        }
        if workspaceRoot == nil {
            let markers = ["/Sources/", "/scripts/", "/Resources/", "/Tests/"]
            for marker in markers {
                if let range = expanded.range(of: marker) {
                    return String(expanded[expanded.index(after: range.lowerBound)...])
                }
            }
        }
        return value
    }

    static func expandedPath(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("file://") {
            value = String(value.dropFirst(7))
        }
        if value.hasPrefix("~/") {
            value = NSHomeDirectory() + String(value.dropFirst(1))
        }
        if value.hasPrefix("/") {
            return (value as NSString).standardizingPath
        }
        return value
    }

    private static func jsonPath(_ object: [String: Any]) -> String? {
        jsonString(object, keys: ["path", "filePath", "file_path", "target_file", "targetFile", "filename", "file"])
    }

    private static func jsonInt(_ object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? Int { return value }
            if let value = object[key] as? Double { return Int(value) }
            if let value = object[key] as? String, let parsed = Int(value) { return parsed }
        }
        return nil
    }

    private static func jsonString(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func pathFromLooseJSON(_ raw: String?) -> FileChange? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        guard let literal = jsonPathLiteral(trimmed), let path = cleanedPath(literal) else {
            return nil
        }
        return FileChange(path: path, additions: nil, deletions: nil, kind: .edit)
    }

    private static func diffPath(from rest: String) -> String? {
        let firstLine = rest.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? rest
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("--git ") {
            let parts = trimmed.dropFirst(6).split(separator: " ").map(String.init)
            guard var value = parts.last else { return nil }
            if value.hasPrefix("b/") { value = String(value.dropFirst(2)) }
            if value.hasPrefix("a/") { value = String(value.dropFirst(2)) }
            return cleanedPath(value)
        }
        return cleanedPath(trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? trimmed)
    }

    private static func jsonPathLiteral(_ raw: String) -> String? {
        let pattern = #"(?i)"(?:path|filePath|file_path|target_file|targetFile|filename)"\s*:\s*"((?:\\.|[^"\\])*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range),
              let valueRange = Range(match.range(at: 1), in: raw) else {
            return nil
        }
        return String(raw[valueRange])
    }

    private static func unescapePathFragment(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(raw.count)
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character == "\\" {
                let next = raw.index(after: index)
                guard next < raw.endIndex else { break }
                switch raw[next] {
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                case "'": result.append("'")
                case "/": result.append("/")
                case "n", "r", "t":
                    break
                default:
                    result.append(raw[next])
                }
                index = raw.index(after: next)
                continue
            }
            result.append(character)
            index = raw.index(after: index)
        }
        return result
    }

    private static func stripWrappingQuotes(_ raw: String) -> String {
        var value = raw
        while value.count >= 2 {
            let first = value.first
            let last = value.last
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") || (first == "`" && last == "`") {
                value.removeFirst()
                value.removeLast()
                value = value.trimmingCharacters(in: .whitespaces)
                continue
            }
            break
        }
        if value.first == "\"" || value.first == "'" || value.first == "`" {
            value.removeFirst()
        }
        return value
    }

    private static func stripTrailingPathJunk(_ raw: String) -> String {
        var value = raw
        let junk = CharacterSet(charactersIn: "\"'` ,;)]}")
        while !value.isEmpty {
            if value.hasSuffix("\\n") || value.hasSuffix("\\r") || value.hasSuffix("\\t") {
                value.removeLast(2)
                continue
            }
            if value.hasSuffix("\\") {
                value.removeLast()
                continue
            }
            if let last = value.unicodeScalars.last, junk.contains(last) {
                value.removeLast()
                continue
            }
            break
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isPlausibleFilePath(_ value: String) -> Bool {
        let banned = ["null", "undefined", "none", "nil", "true", "false", "dev/null", "/dev/null"]
        if value.isEmpty || value.count > 480 { return false }
        if banned.contains(value.lowercased()) { return false }
        if value.hasPrefix("{") || value.hasPrefix("[") { return false }
        if value.contains("\"") || value.contains("'") || value.contains("`") { return false }
        if value.range(of: #"[,\s，。；、]"#, options: .regularExpression) != nil { return false }
        let last = (value as NSString).lastPathComponent
        guard !last.isEmpty, last != "/" else { return false }
        if banned.contains(last.lowercased()) { return false }
        let ext = (last as NSString).pathExtension
        if ext.isEmpty {
            guard value.contains("/"), last.count >= 2 else { return false }
            return last.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".contains(Character($0)) }
        }
        guard (1...8).contains(ext.count), ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            return false
        }
        let stem = (last as NSString).deletingPathExtension
        return !stem.isEmpty
    }
}
