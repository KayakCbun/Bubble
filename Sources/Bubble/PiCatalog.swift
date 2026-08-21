import Foundation

struct PiSkill: Equatable {
    var name: String
    var description: String
    var path: String
}

struct PiPrompt: Equatable {
    var name: String
    var description: String
    var hint: String?
}

struct WorkspaceFile: Equatable {
    var displayPath: String
    var absolutePath: String

    var name: String {
        URL(fileURLWithPath: displayPath).lastPathComponent
    }
}

struct PromptAttachment: Equatable {
    var uri: String
    var name: String
}

struct PromptImage: Equatable {
    var mimeType: String
    var data: Data
}

enum PiCatalog {
    private static let skipDirectories: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", "DerivedData",
        ".swiftpm", "Pods", ".venv", "venv", "__pycache__", ".next", "target",
        ".gradle", ".idea",
    ]

    static func loadSkills(workspace: URL) -> [PiSkill] {
        var skills: [PiSkill] = []
        var seen = Set<String>()

        func add(_ incoming: [PiSkill]) {
            for skill in incoming where seen.insert(skill.name).inserted {
                skills.append(skill)
            }
        }

        add(loadSkills(from: OverlayPaths.piAgent.appendingPathComponent("skills", isDirectory: true), includeRootMarkdown: true))
        add(loadSkills(from: OverlayPaths.userAgentsSkills, includeRootMarkdown: false))
        for extra in settingsSkillDirectories(workspace: workspace) {
            add(loadSkills(from: extra, includeRootMarkdown: true))
        }
        add(loadSkills(from: workspace.appendingPathComponent(".pi/skills", isDirectory: true), includeRootMarkdown: true))
        for folder in ancestorAgentSkillFolders(from: workspace) {
            add(loadSkills(from: folder, includeRootMarkdown: false))
        }
        return skills.sorted { $0.name < $1.name }
    }

    static func projectSkillNames(at root: URL) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        let candidates = [
            root.appendingPathComponent(".pi/skills", isDirectory: true),
            root.appendingPathComponent(".agents/skills", isDirectory: true),
            root.appendingPathComponent("workspace/.pi/skills", isDirectory: true),
            root.appendingPathComponent("workspace/.agents/skills", isDirectory: true),
        ]
        for directory in candidates {
            for skill in loadSkills(from: directory, includeRootMarkdown: true) {
                if seen.insert(skill.name).inserted {
                    names.append(skill.name)
                }
            }
        }
        return names.sorted()
    }

    static func loadPrompts(workspace: URL) -> [PiPrompt] {
        var prompts: [PiPrompt] = []
        var seen = Set<String>()
        func add(_ incoming: [PiPrompt]) {
            for prompt in incoming where seen.insert(prompt.name).inserted {
                prompts.append(prompt)
            }
        }
        add(loadPrompts(from: OverlayPaths.piAgent.appendingPathComponent("prompts", isDirectory: true)))
        add(loadPrompts(from: workspace.appendingPathComponent(".pi/prompts", isDirectory: true)))
        return prompts.sorted { $0.name < $1.name }
    }

    static func indexFiles(workspace: URL) -> [WorkspaceFile] {
        var files: [WorkspaceFile] = []
        var visited = Set<String>()
        walkFiles(
            workspace,
            relative: "",
            depth: 0,
            files: &files,
            visited: &visited
        )
        return files.sorted { $0.displayPath < $1.displayPath }
    }

    static func pathCompletions(query: String, workspace: URL) -> [WorkspaceFile] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let expanded: URL
        let keepHome: Bool
        if trimmed == "~" {
            expanded = OverlayPaths.home
            keepHome = true
        } else if trimmed.hasPrefix("~/") {
            expanded = OverlayPaths.home.appendingPathComponent(String(trimmed.dropFirst(2)))
            keepHome = true
        } else if trimmed.hasPrefix("/") {
            expanded = URL(fileURLWithPath: trimmed)
            keepHome = false
        } else if trimmed.contains("/") {
            expanded = workspace.appendingPathComponent(trimmed)
            keepHome = false
        } else {
            return []
        }

        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let listingDirectory: URL
        let prefix: String
        if fm.fileExists(atPath: expanded.path, isDirectory: &isDirectory),
           isDirectory.boolValue,
           trimmed.hasSuffix("/") || trimmed == "~" {
            listingDirectory = expanded
            prefix = ""
        } else {
            listingDirectory = expanded.deletingLastPathComponent()
            prefix = expanded.lastPathComponent.lowercased()
        }

        guard let names = try? fm.contentsOfDirectory(atPath: listingDirectory.path) else {
            return []
        }

        return names
            .filter { !$0.hasPrefix(".") }
            .filter { prefix.isEmpty || $0.lowercased().hasPrefix(prefix) }
            .sorted()
            .prefix(40)
            .map { name in
                let absolute = listingDirectory.appendingPathComponent(name).path
                let display: String
                if keepHome {
                    let home = OverlayPaths.home.path
                    if absolute == home {
                        display = "~"
                    } else if absolute.hasPrefix(home + "/") {
                        display = "~/" + String(absolute.dropFirst(home.count + 1))
                    } else {
                        display = absolute
                    }
                } else if trimmed.hasPrefix("/") {
                    display = absolute
                } else if let relative = relativePath(absolute, to: workspace) {
                    display = relative
                } else {
                    display = absolute
                }
                return WorkspaceFile(displayPath: display, absolutePath: absolute)
            }
    }

    static func attachments(in text: String, workspace: URL) -> [PromptAttachment] {
        let pattern = #"(?<![^\s])@([^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var seen = Set<String>()
        var result: [PromptAttachment] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            let token = ns.substring(with: match.range(at: 1))
            guard let resolved = resolveMention(token, workspace: workspace) else { return }
            guard seen.insert(resolved.path).inserted else { return }
            result.append(
                PromptAttachment(
                    uri: URL(fileURLWithPath: resolved.path).absoluteString,
                    name: resolved.lastPathComponent
                )
            )
        }
        return result
    }

    private static func resolveMention(_ token: String, workspace: URL) -> URL? {
        let fm = FileManager.default
        let candidates: [URL]
        if token == "~" {
            candidates = [OverlayPaths.home]
        } else if token.hasPrefix("~/") {
            candidates = [OverlayPaths.home.appendingPathComponent(String(token.dropFirst(2)))]
        } else if token.hasPrefix("/") {
            candidates = [URL(fileURLWithPath: token)]
        } else {
            candidates = [
                workspace.appendingPathComponent(token),
                OverlayPaths.home.appendingPathComponent(token),
            ]
        }
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    private static func loadSkills(from directory: URL, includeRootMarkdown: Bool) -> [PiSkill] {
        loadSkills(from: directory, includeRootMarkdown: includeRootMarkdown, root: directory, visited: [])
    }

    private static func loadSkills(
        from directory: URL,
        includeRootMarkdown: Bool,
        root: URL,
        visited: Set<String>
    ) -> [PiSkill] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        let canonical = directory.resolvingSymlinksInPath().path
        var visited = visited
        guard visited.insert(canonical).inserted else { return [] }

        let skillFile = directory.appendingPathComponent("SKILL.md")
        if fm.fileExists(atPath: skillFile.path),
           let skill = skill(from: skillFile, fallbackName: directory.lastPathComponent) {
            return [skill]
        }

        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return []
        }

        var skills: [PiSkill] = []
        for name in names.sorted() {
            if name.hasPrefix(".") || skipDirectories.contains(name) { continue }
            let child = directory.appendingPathComponent(name)
            var childIsDirectory: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &childIsDirectory) else { continue }
            if childIsDirectory.boolValue {
                skills.append(
                    contentsOf: loadSkills(
                        from: child,
                        includeRootMarkdown: false,
                        root: root,
                        visited: visited
                    )
                )
            } else if includeRootMarkdown, name.lowercased().hasSuffix(".md"),
                      let skill = skill(from: child, fallbackName: (name as NSString).deletingPathExtension) {
                skills.append(skill)
            }
        }
        return skills
    }

    private static func skill(from file: URL, fallbackName: String) -> PiSkill? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let fields = Frontmatter.parse(text)
        let description = fields["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !description.isEmpty else { return nil }
        let name = fields["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (name?.isEmpty == false ? name! : fallbackName)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        return PiSkill(name: resolved, description: description, path: file.path)
    }

    private static func loadPrompts(from directory: URL) -> [PiPrompt] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var prompts: [PiPrompt] = []
        for case let file as URL in enumerator {
            guard file.pathExtension.lowercased() == "md" else { continue }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let fields = Frontmatter.parse(text)
            let name = (file.deletingPathExtension().lastPathComponent)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let description = fields["description"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? firstNonEmptyLine(in: Frontmatter.body(of: text))
                ?? name
            prompts.append(
                PiPrompt(
                    name: name,
                    description: description,
                    hint: fields["argument-hint"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }
        return prompts
    }

    private static func walkFiles(
        _ directory: URL,
        relative: String,
        depth: Int,
        files: inout [WorkspaceFile],
        visited: inout Set<String>
    ) {
        guard depth < 8, files.count < 3000 else { return }
        let fm = FileManager.default
        let canonical = directory.resolvingSymlinksInPath().path
        guard visited.insert(canonical).inserted else { return }
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            if name.hasPrefix(".") || skipDirectories.contains(name) { continue }
            let child = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDirectory) else { continue }
            let childRelative = relative.isEmpty ? name : relative + "/" + name
            if isDirectory.boolValue {
                walkFiles(child, relative: childRelative, depth: depth + 1, files: &files, visited: &visited)
            } else {
                files.append(WorkspaceFile(displayPath: childRelative, absolutePath: child.path))
            }
        }
    }

    private static func settingsSkillDirectories(workspace: URL) -> [URL] {
        let files = [
            OverlayPaths.piAgent.appendingPathComponent("settings.json"),
            workspace.appendingPathComponent(".pi/settings.json"),
        ]
        var directories: [URL] = []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let values = json.array("skills") ?? []
            for value in values {
                guard let raw = value as? String, !raw.isEmpty else { continue }
                directories.append(expandPath(raw, relativeTo: file.deletingLastPathComponent()))
            }
        }
        return directories
    }

    private static func ancestorAgentSkillFolders(from workspace: URL) -> [URL] {
        var folders: [URL] = []
        var current = workspace
        let fm = FileManager.default
        for _ in 0..<8 {
            let candidate = current.appendingPathComponent(".agents/skills", isDirectory: true)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                folders.append(candidate)
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return folders
    }

    private static func expandPath(_ raw: String, relativeTo base: URL) -> URL {
        if raw.hasPrefix("~/") {
            return OverlayPaths.home.appendingPathComponent(String(raw.dropFirst(2)))
        }
        if raw == "~" {
            return OverlayPaths.home
        }
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw)
        }
        return base.appendingPathComponent(raw)
    }

    private static func relativePath(_ absolute: String, to workspace: URL) -> String? {
        let root = workspace.path.hasSuffix("/") ? workspace.path : workspace.path + "/"
        guard absolute.hasPrefix(root) else { return nil }
        return String(absolute.dropFirst(root.count))
    }

    private static func firstNonEmptyLine(in text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}

enum Frontmatter {
    static func parse(_ text: String) -> [String: String] {
        guard text.hasPrefix("---") else { return [:] }
        let remainder = text.dropFirst(3).drop(while: { $0 == "\n" || $0 == "\r" })
        guard let end = remainder.range(of: "\n---") else { return [:] }
        let yaml = remainder[remainder.startIndex..<end.lowerBound]
        var fields: [String: String] = [:]
        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty {
                fields[key] = value
            }
        }
        return fields
    }

    static func body(of text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let remainder = text.dropFirst(3).drop(while: { $0 == "\n" || $0 == "\r" })
        guard let end = remainder.range(of: "\n---") else { return text }
        let after = remainder[end.upperBound...]
        return String(after.drop(while: { $0 == "\n" || $0 == "\r" }))
    }
}
