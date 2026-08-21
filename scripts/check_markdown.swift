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
struct MarkdownFilesCheck {
    static func main() throws {
        expect(MarkdownFiles.isMarkdown(path: "SKILL.md"), "SKILL.md is markdown")
        expect(MarkdownFiles.isMarkdown(ext: "markdown"), "markdown ext")
        expect(!MarkdownFiles.isMarkdown(path: "main.swift"), "swift is not markdown")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-md-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let readme = nested.appendingPathComponent("README.md")
        try "# Hello\n".write(to: readme, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        expect(
            sameFile(MarkdownFiles.resolve(readme.path, workspace: root.path), readme.path),
            "absolute path stays put"
        )
        expect(
            sameFile(MarkdownFiles.resolve("docs/README.md", workspace: root.path), readme.path),
            "relative path resolves against workspace"
        )
        expect(
            sameFile(MarkdownFiles.resolve("README.md", workspace: "/missing", extraRoots: [nested.path]), readme.path),
            "filename resolves against extra roots"
        )
        expect(
            sameFile(MarkdownFiles.resolve("file://\(readme.path)", workspace: root.path), readme.path),
            "file URL resolves to the path"
        )
        let spaced = nested.appendingPathComponent("My Note.md")
        try "# Spaced\n".write(to: spaced, atomically: true, encoding: .utf8)
        expect(
            sameFile(MarkdownFiles.resolve("file://\(spaced.path)", workspace: root.path), spaced.path),
            "file URL with spaces resolves"
        )
        let loaded = MarkdownFiles.load(path: readme.path)
        expect(loaded.error == nil, "load succeeds")
        expect(loaded.source.contains("# Hello"), "load reads the file")
        expect(loaded.title == "README.md", "title is the filename")
        let missing = MarkdownFiles.load(path: root.appendingPathComponent("nope.md").path)
        expect(missing.error != nil, "missing file is an error")
        let huge = Data(repeating: 0x61, count: MarkdownFiles.maxBytes + 1)
        let hugeURL = nested.appendingPathComponent("huge.md")
        try huge.write(to: hugeURL)
        expect(MarkdownFiles.load(path: hugeURL.path).error != nil, "oversized file is an error")
        expect(
            sameFile(MarkdownFiles.resolve("README.md.", workspace: root.path), readme.path),
            "trailing punctuation is stripped"
        )
        expect(
            sameFile(MarkdownFiles.resolve("\"docs/README.md\"", workspace: root.path), readme.path),
            "quoted relative path resolves"
        )
        expect(
            sameFile(MarkdownFiles.resolve("README.md", workspace: root.path), readme.path),
            "filename is found in a nested workspace folder"
        )
        expect(
            sameFile(MarkdownFiles.resolve("README.md", workspace: root.path), readme.path),
            "relative names resolve inside the workspace, not the process cwd"
        )
        let skillDir = root.appendingPathComponent(".pi/skills/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let skill = skillDir.appendingPathComponent("SKILL.md")
        try "# Skill\n".write(to: skill, atomically: true, encoding: .utf8)
        expect(
            sameFile(MarkdownFiles.resolve("SKILL.md", workspace: root.path), skill.path),
            "filename is found under hidden skill folders"
        )
        expect(
            MarkdownFiles.sanitizePath("/Users/x/.agents/skills/lark-oncall-\nreview/SKILL.md")
                == "/Users/x/.agents/skills/lark-oncall-review/SKILL.md",
            "newlines inside a path are stripped"
        )
        print("PASS: markdown files")
    }
}
