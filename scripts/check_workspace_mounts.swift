import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct WorkspaceMountsCheck {
    static let home = URL(fileURLWithPath: "/Users/ada")
    static let bubbleRoot = URL(fileURLWithPath: "/Users/ada/.bubble")
    static let workspace = URL(fileURLWithPath: "/Users/ada/.bubble/workspace")

    static func main() throws {
        try mountAndUnmount()
        cannotMountBubbleHome()
        try cannotUnmountRunning()
        try resolveByNameAndPath()
        try statusBlock()
        interruptActive()
        injectionRoundTrip()
        completedRunRelaysFinalResponseDirectly()
        inferWaiting()
        paletteBrowseLast()
        try paletteDrillDown()
        enterAndParentQuery()
        print("PASS: workspace mounts")
    }

    static func mountAndUnmount() throws {
        var store = WorkspaceStoreFile()
        try WorkspaceRegistry.mount(
            path: "/Users/ada/work/oncall-watcher",
            in: &store,
            bubbleRoot: bubbleRoot.path,
            workspace: workspace.path
        )
        expect(store.mounts.count == 1, "mount should add one entry")
        expect(store.mounts[0].name == "oncall-watcher", "name is folder name")
        try WorkspaceRegistry.unmount(path: "/Users/ada/work/oncall-watcher", in: &store)
        expect(store.mounts.isEmpty, "unmount removes the entry")

        var sessionScoped = WorkspaceStoreFile(
            mounts: [WorkspaceMount(path: "/tmp/work-a", name: "work-a", sessionId: "child-old")],
            recent: [WorkspaceMount(path: "/tmp/work-b", name: "work-b", sessionId: "child-recent")]
        )
        expect(
            WorkspaceRegistry.sessionId(forMountPath: "/tmp/./work-a", in: sessionScoped) == "child-old",
            "session lookup follows normalized mount identity"
        )
        expect(
            WorkspaceRegistry.sessionId(forMountPath: "/tmp/work-b", in: sessionScoped) == nil,
            "session lookup does not inherit a recent unmounted workspace"
        )
        WorkspaceRegistry.resetSessions(in: &sessionScoped)
        expect(sessionScoped.mounts.count == 1, "new main session keeps mounted folders")
        expect(sessionScoped.mounts[0].sessionId == nil, "new main session creates fresh workspace sessions")
        expect(sessionScoped.recent[0].sessionId == nil, "recent mounts cannot revive an old main session's child")
        expect(store.recent.count == 1, "unmount keeps a recent entry")
    }

    static func cannotMountBubbleHome() {
        var store = WorkspaceStoreFile()
        do {
            try WorkspaceRegistry.mount(
                path: "/Users/ada/.bubble",
                in: &store,
                bubbleRoot: bubbleRoot.path,
                workspace: workspace.path
            )
            expect(false, "mounting ~/.bubble should fail")
        } catch WorkspaceError.protectedPath {
            return
        } catch {
            expect(false, "unexpected error \(error)")
        }
    }

    static func cannotUnmountRunning() throws {
        var store = WorkspaceStoreFile()
        try WorkspaceRegistry.mount(
            path: "/Users/ada/work/a",
            in: &store,
            bubbleRoot: bubbleRoot.path,
            workspace: workspace.path
        )
        store.active = WorkspaceBrief(
            path: WorkspaceRegistry.normalize("/Users/ada/work/a"),
            name: "a",
            status: .running,
            goal: "fix tests"
        )
        do {
            try WorkspaceRegistry.unmount(path: "/Users/ada/work/a", in: &store)
            expect(false, "unmounting a running workspace should fail")
        } catch WorkspaceError.running {
            return
        } catch {
            expect(false, "unexpected error \(error)")
        }
    }

    static func resolveByNameAndPath() throws {
        var store = WorkspaceStoreFile()
        try WorkspaceRegistry.mount(
            path: "/Users/ada/work/oncall-watcher",
            in: &store,
            bubbleRoot: bubbleRoot.path,
            workspace: workspace.path
        )
        expect(
            WorkspaceRegistry.resolve("oncall-watcher", in: store, home: home)?.name == "oncall-watcher",
            "resolve by name"
        )
        expect(
            WorkspaceRegistry.resolve("~/work/oncall-watcher", in: store, home: home)?.name == "oncall-watcher",
            "resolve by ~ path"
        )
    }

    static func statusBlock() throws {
        var store = WorkspaceStoreFile()
        try WorkspaceRegistry.mount(
            path: "/Users/ada/work/oncall-watcher",
            in: &store,
            bubbleRoot: bubbleRoot.path,
            workspace: workspace.path
        )
        store.active = WorkspaceBrief(
            path: WorkspaceRegistry.normalize("/Users/ada/work/oncall-watcher"),
            name: "oncall-watcher",
            status: .running,
            goal: "fix flaky test",
            summary: "reading tests"
        )
        let block = WorkspaceRegistry.statusBlock(store, home: home.path)
        expect(block.contains("oncall-watcher"), "status lists the mount")
        expect(block.contains("active: oncall-watcher [running]"), "status lists the run")
        let wrapped = WorkspaceRegistry.wrapUserPrompt(
            "hello",
            store: store,
            home: home.path,
            skillsByMount: [store.mounts[0].path: ["birio-bitable", "argos"]]
        )
        expect(wrapped.contains("<bubble-workspace>"), "prompt wrap includes the block")
        expect(wrapped.contains("workspace_run"), "prompt wrap tells the model to dispatch")
        expect(wrapped.contains("birio-bitable"), "prompt wrap lists mount skills")
        expect(wrapped.hasPrefix("hello\n\n<bubble-workspace>"), "Pi session titles start from the user's request")
        expect(wrapped.hasSuffix("</bubble-workspace>"), "workspace metadata follows the user request")
    }

    static func interruptActive() {
        var store = WorkspaceStoreFile()
        store.active = WorkspaceBrief(
            path: "/Users/ada/work/a",
            name: "a",
            status: .running,
            goal: "refactor"
        )
        WorkspaceRegistry.interruptActive(in: &store)
        expect(store.active?.status == .interrupted, "quit marks the run interrupted")
    }

    static func injectionRoundTrip() {
        let brief = WorkspaceBrief(
            runId: "run-123",
            path: "/Users/ada/Documents/work",
            name: "work",
            status: .done,
            goal: "first line\nsummary: this belongs to the goal",
            summary: "summary line one\nquestion: this belongs to the summary",
            question: "continue?",
            changedPaths: ["/tmp/report,final.json"]
        )
        let prompt = WorkspaceRegistry.injectionPrompt(
            brief,
            home: home.path,
            sessionId: "child-456",
            anchorEntryId: "user-789"
        )
        let restored = WorkspaceRegistry.parseInjectionPrompt(prompt, home: home.path)
        expect(restored?.brief == brief, "structured relay payload restores the complete brief losslessly")
        expect(restored?.sessionId == "child-456", "relay prompt restores the child session")
        expect(restored?.anchorEntryId == "user-789", "relay prompt restores the workspace turn anchor")

        let legacy = prompt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("bubble_workspace_relay_v1: ") }
            .joined(separator: "\n")
        let legacyRestored = WorkspaceRegistry.parseInjectionPrompt(legacy, home: home.path)
        expect(legacyRestored?.brief.path == brief.path, "legacy relay prompts remain readable")
        expect(legacyRestored?.brief.runId == nil, "legacy relays do not invent a run identity")
        expect(
            WorkspaceRegistry.canMatchLegacyRelay(
                cardRunId: "legacy-local-run",
                structuredRelayRunIds: ["modern-run"]
            ),
            "a first restore may reuse the identified local card belonging to a legacy relay"
        )
        expect(
            !WorkspaceRegistry.canMatchLegacyRelay(
                cardRunId: "modern-run",
                structuredRelayRunIds: ["modern-run"]
            ),
            "a legacy relay cannot consume a card reserved by a structured relay"
        )
    }

    static func completedRunRelaysFinalResponseDirectly() {
        let finalResponse = "WORKSPACE_FINAL_BEGIN\n" + String(repeating: "完整子会话结论。", count: 180) + "\nWORKSPACE_FINAL_END"
        let brief = WorkspaceBrief(
            runId: "run-direct-final",
            path: "/Users/ada/Documents/work",
            name: "work",
            status: .done,
            goal: "finish the task",
            summary: finalResponse
        )
        let result = WorkspaceRegistry.directResultText(finalResponse, fallback: brief)

        expect(
            result == finalResponse,
            "a completed workspace run must relay its complete final response without summary clipping"
        )
        expect(
            WorkspaceRegistry.directResultText("  ", fallback: brief) == finalResponse,
            "an empty live buffer falls back to the persisted workspace result"
        )
    }

    static func inferWaiting() {
        expect(WorkspaceRegistry.inferWaiting(from: "要不要改 schema？") != nil, "question becomes waiting")
        expect(WorkspaceRegistry.inferWaiting(from: "Tests passed.") == nil, "statement is not waiting")
        expect(
            WorkspaceRegistry.inferWaiting(from: "是否能查询 SV：可以。\n已查阅工作区，未修改文件。") == nil,
            "是否 in a report is not waiting"
        )
    }

    static func paletteBrowseLast() {
        let store = WorkspaceStoreFile(
            mounts: [WorkspaceMount(path: "/Users/ada/work/oncall-watcher", name: "oncall-watcher")]
        )
        let rows = WorkspaceRegistry.paletteRows(
            store: store,
            query: "",
            home: home,
            bubbleRoot: bubbleRoot,
            workspace: workspace,
            fileManager: FileManager.default
        )
        expect(rows.last?.isBrowse == true, "Browse stays last")
        expect(rows.contains(where: { $0.name == "oncall-watcher" && $0.state == .mounted }), "mounted row appears")
        expect(rows.contains(where: { $0.name == "oncall-watcher" && $0.role == "enter" }), "overview rows enter")
    }

    static func enterAndParentQuery() {
        expect(
            WorkspaceRegistry.enterQuery(path: "/Users/ada/Documents/work", home: home) == "~/Documents/work/",
            "enter query uses ~/ and a trailing slash"
        )
        expect(
            WorkspaceRegistry.parentQuery(query: "~/Documents/work/", home: home) == "~/Documents/",
            "parent stays inside the current tree"
        )
        expect(
            WorkspaceRegistry.parentQuery(query: "~/Documents/", home: home) == "",
            "parent of a home child returns to the overview"
        )
    }

    static func paletteDrillDown() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bubble-mounts-\(UUID().uuidString)",
            isDirectory: true
        )
        let child = tmp.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rows = WorkspaceRegistry.paletteRows(
            store: WorkspaceStoreFile(),
            query: tmp.path + "/",
            home: home,
            bubbleRoot: bubbleRoot,
            workspace: workspace
        )
        expect(rows.contains(where: { $0.role == "up" }), "drilled list has a parent row")
        expect(
            rows.contains(where: { $0.role == "toggle" && $0.path == tmp.standardizedFileURL.path }),
            "current folder can be mounted in place"
        )
        expect(
            rows.contains(where: { $0.role == "enter" && $0.name == "inner" }),
            "child folders are enterable"
        )
    }
}
