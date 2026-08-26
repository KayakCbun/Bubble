import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct FileChangeSummaryCheck {
    static func main() {
        expect(
            FileChangeSummaryPolicy.isFileMutation(kind: "edit", title: "search"),
            "edit tools are file mutations"
        )
        expect(
            !FileChangeSummaryPolicy.isFileMutation(kind: "read", title: "Read README.md"),
            "read tools are not file mutations"
        )

        let diff = FileChangeSummaryPolicy.parseDiff(
            "diff Sources/Bubble/OverlayView.swift\n---\nold line\n+++\nnew line\nsecond"
        )
        expect(diff?.path == "Sources/Bubble/OverlayView.swift", "diff path is kept")
        expect(diff?.additions == 2, "diff additions count new lines \(diff?.additions ?? -1)")
        expect(diff?.deletions == 1, "diff deletions count old lines \(diff?.deletions ?? -1)")

        let created = FileChangeSummaryPolicy.parseJSONEdit(
            #"{"path":"scripts/package.sh","contents":"a\nb\nc"}"#
        )
        expect(created?.kind == .create, "write without old text is a create")
        expect(created?.additions == 3, "create additions follow the new file")

        let delta = FileChangeSummaryPolicy.lineDelta(old: "a\nb\nc", new: "a\nx\nc")
        expect(delta.additions == 1 && delta.deletions == 1, "line delta uses collection difference")

        let summary = FileChangeSummaryPolicy.summary(
            id: "turn-1",
            tools: [
                (kind: "edit", title: "Edit Sources/Bubble/A.swift", input: nil, output: "diff Sources/Bubble/A.swift\n---\nold\n+++\nnew"),
                (kind: "write", title: "Write scripts/run.sh", input: #"{"path":"scripts/run.sh","contents":"echo"}"#, output: nil),
                (kind: "read", title: "Read README.md", input: #"{"path":"README.md"}"#, output: nil),
            ]
        )
        expect(summary?.files.count == 2, "read tools are omitted from the card")
        expect(summary?.files.map(\.folder).sorted() == ["Sources/Bubble", "scripts"], "files group by folder")
        expect((summary?.additions ?? 0) > 0, "summary totals additions")

        let empty = FileChangeSummaryPolicy.summary(
            id: "turn-2",
            tools: [(kind: "execute", title: "Run tests", input: nil, output: "ok")]
        )
        expect(empty == nil, "turns without file edits have no card")
        expect(
            FileChangeSummaryPolicy.summary(id: "turn-1", tools: [
                (kind: "edit", title: "Edit Sources/Bubble/A.swift", input: nil, output: "diff Sources/Bubble/A.swift\n---\nold\n+++\nnew"),
                (kind: "write", title: "Write scripts/run.sh", input: #"{"path":"scripts/run.sh","contents":"echo"}"#, output: nil),
                (kind: "read", title: "Read README.md", input: #"{"path":"README.md"}"#, output: nil),
            ]) == summary,
            "identical tool lists reuse the turn summary without reparsing diffs"
        )

        let untitled = FileChangeSummaryPolicy.change(
            kind: "edit",
            title: "Edit Sources/Bubble/OverlayView.swift",
            input: nil,
            output: nil
        )
        expect(untitled?.additions == nil && untitled?.deletions == nil, "path-only edits do not fake +0 -0")
        expect(untitled.map { FileChangeSummary(id: "x", files: [$0]).hasLineStats } == false, "unknown stats stay hidden")
        expect(
            untitled.map(FileChangeCardPolicy.belongsInChangedFiles) == false,
            "path-only mentions do not belong in the changed-files card"
        )
        expect(
            FileChangeSummaryPolicy.summary(
                id: "path-only-turn",
                tools: [(kind: "edit", title: "Edit AGENTS.md", input: nil, output: nil)]
            ) == nil,
            "a turn that only named files has no changed-files card"
        )
        let mixed = FileChangeSummaryPolicy.summary(
            id: "mixed-turn",
            tools: [
                (kind: "edit", title: "Edit AGENTS.md", input: nil, output: nil),
                (kind: "edit", title: "Edit src/app.ts", input: #"{"path":"src/app.ts","oldText":"a","newText":"b"}"#, output: nil),
            ]
        )
        expect(mixed?.files.map(\.fileName) == ["app.ts"], "the card keeps only files with a counted diff \(mixed?.files.map(\.fileName) ?? [])")

        let unified = FileChangeSummaryPolicy.parseUnified("""
        --- a/scripts/run.sh
        +++ b/scripts/run.sh
        @@ -1,2 +1,3 @@
         #!/bin/bash
        -old
        +new
        +extra
        """)
        expect(unified?.path == "scripts/run.sh", "unified diff path")
        expect(unified?.additions == 2 && unified?.deletions == 1, "unified diff counts hunk lines \(unified?.additions ?? -1) \(unified?.deletions ?? -1)")

        expect(FileChangeSummaryPolicy.cleanedPath("AGENTS.md';") == "AGENTS.md", "strip JS quote-semicolon junk")
        expect(FileChangeSummaryPolicy.cleanedPath("AGENTS.md;") == "AGENTS.md", "strip trailing semicolon")
        expect(FileChangeSummaryPolicy.cleanedPath("skills.js';") == "skills.js", "strip quoted JS filename")
        expect(FileChangeSummaryPolicy.cleanedPath("SKILL.md\"") == "SKILL.md", "strip trailing quote")
        expect(
            FileChangeSummaryPolicy.cleanedPath("success-target-mismatch.md\\\",\\\\n") == "success-target-mismatch.md"
                || FileChangeSummaryPolicy.cleanedPath(#"success-target-mismatch.md",\n"#) == "success-target-mismatch.md",
            "strip JSON quote-comma-newline junk \(FileChangeSummaryPolicy.cleanedPath(#"success-target-mismatch.md",\n"#) ?? "nil")"
        )
        expect(FileChangeSummaryPolicy.cleanedPath("null") == nil, "null is not a file")
        expect(FileChangeSummaryPolicy.cleanedPath("null;") == nil, "null; is not a file")
        expect(FileChangeSummaryPolicy.cleanedPath("覆盖能解释差异时，由") == nil, "prose is not a file")
        expect(
            FileChangeSummaryPolicy.path(fromTitle: "Edit AGENTS.md'; leftover text") == "AGENTS.md",
            "edit titles keep the first path token only"
        )
        expect(
            FileChangeSummaryPolicy.change(
                kind: "write",
                title: "Write file",
                input: #"not json "path": "docs/SKILL.md" trailing"#,
                output: nil
            ) == nil,
            "prose that mentions a path field is not a file change"
        )
        let escaped = FileChangeSummaryPolicy.cleanedPath(
            #"~/.agents/skills/bytedcli/SKILL.md""#
        )
        expect(escaped == "~/.agents/skills/bytedcli/SKILL.md", "quoted absolute-looking skill path \(escaped ?? "nil")")

        expect(!FileChangeCardPolicy.expandsByDefault, "changed-file cards start collapsed")
        expect(
            !FileChangeCardPolicy.isExpanded(id: "files-1", expandedIDs: []),
            "a new card is collapsed until the user opens it"
        )

        let workspaceRoot = "/tmp/bubble-workspace-demo"
        expect(
            FileChangeSummaryPolicy.cleanedPath(
                "\(workspaceRoot)/src/app.ts",
                workspaceRoot: workspaceRoot
            ) == "src/app.ts",
            "workspace files display relative to that workspace"
        )
        expect(
            FileChangeSummaryPolicy.resolvedPath("src/app.ts", workspaceRoot: workspaceRoot)
                == "\(workspaceRoot)/src/app.ts",
            "opening a workspace file uses that workspace root"
        )
        expect(
            FileChangeSummaryPolicy.pathHint(
                kind: "edit",
                title: "Edit src/app.ts",
                input: #"{"path":"src/app.ts","oldText":"a","newText":"b"}"#,
                output: nil,
                workspaceRoot: workspaceRoot
            ) == "src/app.ts",
            "relative workspace edits are detected"
        )
        expect(
            FileChangeSummaryPolicy.pathHint(
                kind: "execute",
                title: "Run tests",
                input: nil,
                output: "see /dev/null and /feat/foo"
            ) == nil,
            "execute output must not harvest random absolute paths"
        )
        expect(
            FileChangeSummaryPolicy.uniqueDisplayPaths(
                ["\(workspaceRoot)/src/app.ts", "src/app.ts", "null;", "覆盖能解释差异时，由"],
                workspaceRoot: workspaceRoot
            ) == ["src/app.ts"],
            "workspace path lists stay unique and drop junk"
        )

        print("PASS: file change summary")
    }
}
