import Foundation

enum FilePreviewFormat: Equatable {
    case markdown
    case plainText(language: String)
}

struct FilePreviewDocument: Equatable {
    var path: String
    var title: String
    var source: String
    var error: String?
    var format: FilePreviewFormat = .markdown
}

enum PreviewFiles {
    static let markdownExtensions: Set<String> = ["md", "markdown"]
    static let textPreviewExtensions: Set<String> = ["json", "txt", "csv"]
    static let supportedExtensions = markdownExtensions.union(textPreviewExtensions)
    static let maxBytes = 512_000
    private static let skipDirectoryNames: Set<String> = [
        "node_modules", ".git", "DerivedData", ".build", "dist", "Pods", ".swiftpm",
    ]

    static func isMarkdown(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return markdownExtensions.contains(ext)
    }

    static func isMarkdown(ext: String) -> Bool {
        markdownExtensions.contains(ext.lowercased())
    }

    static func isPreviewable(path: String) -> Bool {
        isPreviewable(ext: (path as NSString).pathExtension)
    }

    static func isPreviewable(ext: String) -> Bool {
        supportedExtensions.contains(ext.lowercased())
    }

    static func previewFormat(path: String) -> FilePreviewFormat {
        let ext = (path as NSString).pathExtension.lowercased()
        return markdownExtensions.contains(ext) ? .markdown : .plainText(language: ext)
    }

    static func trimTrailingPunctuation(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrapped: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("<", ">"), ("“", "”"), ("‘", "’")]
        if value.count >= 2,
           let first = value.first,
           let last = value.last,
           wrapped.contains(where: { $0.0 == first && $0.1 == last }) {
            value = String(value.dropFirst().dropLast())
        }
        let extras = CharacterSet(charactersIn: ".,;:)]}>'\"，。、；：）»")
        while let last = value.unicodeScalars.last, extras.contains(last) {
            value.removeLast()
        }
        return value
    }

    static func sanitizePath(_ raw: String) -> String {
        let zw = CharacterSet(charactersIn: "\u{00AD}\u{200B}\u{200C}\u{200D}\u{FEFF}")
        var value = raw.components(separatedBy: zw).joined()
        value = value.replacingOccurrences(of: "\r\n", with: "")
        value = value.replacingOccurrences(of: "\n", with: "")
        value = value.replacingOccurrences(of: "\r", with: "")
        return value
    }

    static func resolve(_ raw: String, workspace: String, extraRoots: [String] = []) -> String {
        let value = stripFileURL(trimTrailingPunctuation(sanitizePath(raw)))
        let expanded = (value as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            let absolute = (expanded as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: absolute) {
                return absolute
            }
        }
        let relative = expanded.hasPrefix("./") ? String(expanded.dropFirst(2)) : expanded
        guard !relative.hasPrefix("/") else {
            let named = (relative as NSString).lastPathComponent
            for root in [workspace] + extraRoots {
                if let found = locate(named, under: root) {
                    return found
                }
            }
            return (expanded as NSString).standardizingPath
        }
        let named = (relative as NSString).lastPathComponent
        let roots = [workspace] + extraRoots
        for root in roots {
            let candidate = ((root as NSString).appendingPathComponent(relative) as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        for root in roots {
            if let found = locate(relative, under: root) {
                return found
            }
        }
        if named != relative {
            for root in roots {
                if let found = locate(named, under: root) {
                    return found
                }
            }
        }
        return ((workspace as NSString).appendingPathComponent(named) as NSString).standardizingPath
    }

    static func locate(_ relative: String, under root: String) -> String? {
        let fm = FileManager.default
        let needle = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !needle.isEmpty else { return nil }
        let named = (needle as NSString).lastPathComponent
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return nil }

        var fallback: String?
        var fallbackDepth = Int.max
        var visits = 0
        while let url = enumerator.nextObject() as? URL {
            visits += 1
            if visits > 6_000 { break }
            if skipDirectoryNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory { continue }
            let path = url.path
            if path.hasSuffix("/" + needle) || path == needle {
                return path
            }
            if url.lastPathComponent == named {
                let depth = url.pathComponents.count
                if depth < fallbackDepth {
                    fallback = path
                    fallbackDepth = depth
                }
            }
        }
        return fallback
    }

    static func stripFileURL(_ raw: String) -> String {
        guard raw.lowercased().hasPrefix("file://") else { return raw }
        if let url = URL(string: raw), url.isFileURL {
            return url.path
        }
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
        if let encoded, let url = URL(string: encoded), url.isFileURL {
            return url.path
        }
        let stripped = String(raw.dropFirst("file://".count))
        return stripped.removingPercentEncoding ?? stripped
    }

    static func load(path: String) -> FilePreviewDocument {
        let path = sanitizePath(path)
        let url = URL(fileURLWithPath: path)
        let title = url.lastPathComponent
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        guard exists else {
            return FilePreviewDocument(path: path, title: title, source: "", error: "File not found.")
        }
        if isDirectory.boolValue {
            return FilePreviewDocument(path: path, title: title, source: "", error: "That path is a folder.")
        }
        let data: Data
        do {
            data = try readFile(at: path)
        } catch {
            return FilePreviewDocument(
                path: path,
                title: title,
                source: "",
                error: "Could not read the file. \((error as NSError).localizedDescription)"
            )
        }
        if data.count > maxBytes {
            return FilePreviewDocument(
                path: path,
                title: title,
                source: "",
                error: "File is too large to preview."
            )
        }
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            return FilePreviewDocument(path: path, title: title, source: "", error: "File is not text.")
        }
        return FilePreviewDocument(
            path: path,
            title: title,
            source: text,
            error: nil,
            format: previewFormat(path: path)
        )
    }

    static func readFile(at path: String) throws -> Data {
        if let data = FileManager.default.contents(atPath: path) {
            return data
        }
        let url = URL(fileURLWithPath: path)
        do {
            return try Data(contentsOf: url, options: [.uncached])
        } catch {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            if let data = try handle.readToEnd() {
                return data
            }
            throw error
        }
    }
}
