import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

func sameFile(_ a: String, _ b: String) -> Bool {
    (a as NSString).resolvingSymlinksInPath == (b as NSString).resolvingSymlinksInPath
}

@main
struct PreviewFilesCheck {
    static func main() throws {
        expect(PreviewFiles.isMarkdown(path: "SKILL.md"), "SKILL.md is markdown")
        expect(PreviewFiles.isMarkdown(ext: "markdown"), "markdown ext")
        expect(!PreviewFiles.isMarkdown(path: "main.swift"), "swift is not markdown")
        expect(PreviewFiles.isPreviewable(path: "settings.json"), "json files are previewable")
        expect(PreviewFiles.isPreviewable(ext: "TXT"), "text files are previewable case-insensitively")
        expect(PreviewFiles.isPreviewable(path: "exports/report.csv"), "csv files are previewable")
        expect(!PreviewFiles.isPreviewable(path: "main.swift"), "unsupported source files still open in Finder")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-preview-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let readme = nested.appendingPathComponent("README.md")
        try "# Hello\n".write(to: readme, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        expect(
            sameFile(PreviewFiles.resolve(readme.path, workspace: root.path), readme.path),
            "absolute path stays put"
        )
        expect(
            sameFile(PreviewFiles.resolve("docs/README.md", workspace: root.path), readme.path),
            "relative path resolves against workspace"
        )
        expect(
            sameFile(PreviewFiles.resolve("README.md", workspace: "/missing", extraRoots: [nested.path]), readme.path),
            "filename resolves against extra roots"
        )
        expect(
            sameFile(PreviewFiles.resolve("file://\(readme.path)", workspace: root.path), readme.path),
            "file URL resolves to the path"
        )
        let spaced = nested.appendingPathComponent("My Note.md")
        try "# Spaced\n".write(to: spaced, atomically: true, encoding: .utf8)
        expect(
            sameFile(PreviewFiles.resolve("file://\(spaced.path)", workspace: root.path), spaced.path),
            "file URL with spaces resolves"
        )
        let loaded = PreviewFiles.load(path: readme.path)
        expect(loaded.error == nil, "load succeeds")
        expect(loaded.source.contains("# Hello"), "load reads the file")
        expect(loaded.title == "README.md", "title is the filename")
        expect(loaded.format == .markdown, "markdown files keep rich rendering")
        let json = nested.appendingPathComponent("settings.json")
        try #"{"enabled":true}"#.write(to: json, atomically: true, encoding: .utf8)
        let loadedJSON = PreviewFiles.load(path: json.path)
        expect(loadedJSON.source == #"{"enabled":true}"#, "json preview reads exact source")
        expect(loadedJSON.format == .plainText(language: "json"), "json preview uses a literal text renderer")
        let text = nested.appendingPathComponent("notes.TXT")
        try "first line\nsecond line\n".write(to: text, atomically: true, encoding: .utf8)
        expect(
            PreviewFiles.load(path: text.path).format == .plainText(language: "txt"),
            "text preview format is case-insensitive"
        )
        let csv = nested.appendingPathComponent("rows.csv")
        try "name,count\nBubble,3\n".write(to: csv, atomically: true, encoding: .utf8)
        expect(
            PreviewFiles.load(path: csv.path).format == .plainText(language: "csv"),
            "csv preview stays literal instead of being parsed as markdown"
        )
        let missing = PreviewFiles.load(path: root.appendingPathComponent("nope.md").path)
        expect(missing.error != nil, "missing file is an error")
        let huge = Data(repeating: 0x61, count: PreviewFiles.maxBytes + 1)
        let hugeURL = nested.appendingPathComponent("huge.md")
        try huge.write(to: hugeURL)
        expect(PreviewFiles.load(path: hugeURL.path).error != nil, "oversized file is an error")
        expect(
            sameFile(PreviewFiles.resolve("README.md.", workspace: root.path), readme.path),
            "trailing punctuation is stripped"
        )
        expect(
            sameFile(PreviewFiles.resolve("\"docs/README.md\"", workspace: root.path), readme.path),
            "quoted relative path resolves"
        )
        expect(
            sameFile(PreviewFiles.resolve("README.md", workspace: root.path), readme.path),
            "filename is found in a nested workspace folder"
        )
        expect(
            sameFile(PreviewFiles.resolve("README.md", workspace: root.path), readme.path),
            "relative names resolve inside the workspace, not the process cwd"
        )
        let skillDir = root.appendingPathComponent(".pi/skills/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let skill = skillDir.appendingPathComponent("SKILL.md")
        try "# Skill\n".write(to: skill, atomically: true, encoding: .utf8)
        expect(
            sameFile(PreviewFiles.resolve("SKILL.md", workspace: root.path), skill.path),
            "filename is found under hidden skill folders"
        )
        expect(
            PreviewFiles.sanitizePath("/Users/x/.agents/skills/lark-oncall-\nreview/SKILL.md")
                == "/Users/x/.agents/skills/lark-oncall-review/SKILL.md",
            "newlines inside a path are stripped"
        )
        print("PASS: file preview")
    }
}
