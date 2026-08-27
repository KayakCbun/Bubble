import Foundation
import Testing
import BubbleMounts

struct WorkspaceMountsTests {
    let home = URL(fileURLWithPath: "/Users/ada")
    let bubbleRoot = URL(fileURLWithPath: "/Users/ada/.bubble")
    let workspace = URL(fileURLWithPath: "/Users/ada/.bubble/workspace")

    @Test func mountAndUnmountPersistRecent() throws {
        var store = WorkspaceStoreFile()
        try WorkspaceRegistry.mount(
            path: "/Users/ada/work/oncall-watcher",
            in: &store,
            bubbleRoot: bubbleRoot.path,
            workspace: workspace.path
        )
        #expect(store.mounts.count == 1)
        #expect(store.mounts[0].name == "oncall-watcher")

        try WorkspaceRegistry.unmount(path: "/Users/ada/work/oncall-watcher", in: &store)
        #expect(store.mounts.isEmpty)
        #expect(store.recent.count == 1)
        #expect(store.recent[0].name == "oncall-watcher")
    }

    @Test func sessionLookupUsesMountedWorkspaceIdentity() {
        let store = WorkspaceStoreFile(
            mounts: [WorkspaceMount(path: "/tmp/work-a", name: "work-a", sessionId: "child-a")],
            recent: [WorkspaceMount(path: "/tmp/work-b", name: "work-b", sessionId: "child-b")]
        )
        #expect(WorkspaceRegistry.sessionId(forMountPath: "/tmp/./work-a", in: store) == "child-a")
        #expect(WorkspaceRegistry.sessionId(forMountPath: "/tmp/work-b", in: store) == nil)
        #expect(WorkspaceRegistry.sessionId(forMountPath: nil, in: store) == nil)
    }

    @Test func cannotMountBubbleHome() {
        var store = WorkspaceStoreFile()
        #expect(throws: WorkspaceError.protectedPath) {
            try WorkspaceRegistry.mount(
                path: "/Users/ada/.bubble",
                in: &store,
                bubbleRoot: bubbleRoot.path,
                workspace: workspace.path
            )
        }
    }

    @Test func cannotUnmountRunning() throws {
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
        #expect(throws: WorkspaceError.running) {
            try WorkspaceRegistry.unmount(path: "/Users/ada/work/a", in: &store)
        }
    }

    @Test func resolveByNameAndPath() throws {
        var store = WorkspaceStoreFile()
        try WorkspaceRegistry.mount(
            path: "/Users/ada/work/oncall-watcher",
            in: &store,
            bubbleRoot: bubbleRoot.path,
            workspace: workspace.path
        )
        #expect(WorkspaceRegistry.resolve("oncall-watcher", in: store, home: home)?.name == "oncall-watcher")
        #expect(WorkspaceRegistry.resolve("~/work/oncall-watcher", in: store, home: home)?.name == "oncall-watcher")
    }

    @Test func toggleRoundTrip() throws {
        var store = WorkspaceStoreFile()
        let path = "/Users/ada/Documents/work"
        #expect(
            try WorkspaceRegistry.toggle(
                path: path,
                in: &store,
                bubbleRoot: bubbleRoot.path,
                workspace: workspace.path
            ) == "mounted"
        )
        #expect(
            try WorkspaceRegistry.toggle(
                path: path,
                in: &store,
                bubbleRoot: bubbleRoot.path,
                workspace: workspace.path
            ) == "unmounted"
        )
    }

    @Test func statusBlockAndWrap() throws {
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
        #expect(block.contains("oncall-watcher"))
        #expect(block.contains("active: oncall-watcher [running]"))

        let wrapped = WorkspaceRegistry.wrapUserPrompt("hello", store: store, home: home.path)
        #expect(wrapped.contains("<bubble-workspace>"))
        #expect(wrapped.hasSuffix("hello"))
    }

    @Test func interruptActive() {
        var store = WorkspaceStoreFile()
        store.active = WorkspaceBrief(
            path: "/Users/ada/work/a",
            name: "a",
            status: .running,
            goal: "refactor"
        )
        WorkspaceRegistry.interruptActive(in: &store)
        #expect(store.active?.status == .interrupted)
    }

    @Test func inferWaiting() {
        #expect(WorkspaceRegistry.inferWaiting(from: "要不要改 schema？") != nil)
        #expect(WorkspaceRegistry.inferWaiting(from: "Tests passed.") == nil)
    }

    @Test func palettePutsBrowseLast() {
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
        #expect(rows.last?.isBrowse == true)
        #expect(rows.contains(where: { $0.name == "oncall-watcher" && $0.state == .mounted }))
    }
}
