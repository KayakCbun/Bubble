import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct SideStageCheck {
    static func main() {
        expect(
            SideStagePolicy.width(
                showingMarkdown: false,
                showingWorkspace: false,
                markdownWidth: 440,
                workspaceWidth: 760
            ) == 0,
            "closed stage adds no width"
        )
        expect(
            SideStagePolicy.width(
                showingMarkdown: true,
                showingWorkspace: true,
                markdownWidth: 440,
                workspaceWidth: 760
            ) == 440,
            "stacked markdown uses preview width"
        )
        expect(
            SideStagePolicy.width(
                showingMarkdown: false,
                showingWorkspace: true,
                markdownWidth: 440,
                workspaceWidth: 760
            ) == 760,
            "workspace session uses default transcript width"
        )
        expect(
            SideStagePolicy.showsWorkspaceTranscript(showingMarkdown: true, showingWorkspace: true) == false,
            "stacked markdown hides the workspace transcript"
        )
        expect(
            SideStagePolicy.canReturnToWorkspace(showingMarkdown: true, workspaceStacked: true),
            "markdown opened from a workspace session can return"
        )
        expect(
            !SideStagePolicy.canReturnToWorkspace(showingMarkdown: true, workspaceStacked: false),
            "main-transcript markdown has no back stack"
        )
        expect(SideStagePolicy.followLatest(status: "running"), "live cards follow the tail")
        expect(SideStagePolicy.followLatest(status: "waiting"), "waiting cards follow the tail")
        expect(!SideStagePolicy.followLatest(status: "done"), "finished cards do not follow")
        expect(
            SideStagePolicy.escapeAction(
                showingMarkdown: true,
                workspaceStacked: true,
                showingWorkspace: true
            ) == .returnToWorkspace,
            "escape on stacked markdown returns to the session"
        )
        expect(
            SideStagePolicy.escapeAction(
                showingMarkdown: true,
                workspaceStacked: false,
                showingWorkspace: false
            ) == .closeStage,
            "escape on main markdown closes the stage"
        )
        expect(
            SideStagePolicy.escapeAction(
                showingMarkdown: false,
                workspaceStacked: false,
                showingWorkspace: true
            ) == .closeStage,
            "escape on the workspace session closes the stage"
        )
        let card = UUID()
        expect(SideStagePolicy.shouldToggleClosed(openCardId: card, tappedCardId: card), "same card closes")
        expect(!SideStagePolicy.shouldToggleClosed(openCardId: card, tappedCardId: UUID()), "other card replaces")
        expect(
            SideStagePolicy.keepWorkspaceWhenOpeningMarkdown(fromWorkspacePane: true),
            "links inside the workspace pane keep the session stacked"
        )
        expect(
            !SideStagePolicy.keepWorkspaceWhenOpeningMarkdown(fromWorkspacePane: false),
            "links in the main transcript replace the stage"
        )

        let turns = [
            ("a", "first goal"),
            ("b", "second goal"),
            ("c", "third goal"),
        ]
        expect(
            SideStagePolicy.anchorEntryId(stored: "b", goal: "third goal", cardIndex: 2, turns: turns) == "b",
            "stored anchors win when still in the tree"
        )
        expect(
            SideStagePolicy.anchorEntryId(stored: nil, goal: "second goal", cardIndex: 1, turns: turns) == "b",
            "goal text maps onto its workspace user turn"
        )
        expect(
            SideStagePolicy.anchorEntryId(stored: nil, goal: "third goal", cardIndex: 0, turns: turns) == "c",
            "goal matching wins over a stale card index"
        )
        expect(
            SideStagePolicy.anchorEntryId(stored: nil, goal: "unknown goal", cardIndex: 1, turns: turns) == "b",
            "card index remains the final legacy fallback when goal matching fails"
        )
        expect(
            SideStagePolicy.matchUserTurn(goal: "third goal", turns: turns) == "c",
            "goal text matches the corresponding user turn"
        )
        expect(
            SideStagePolicy.scrollTarget(followLatest: true, anchorEntryId: "b") == "workspace-end",
            "live follow targets the tail"
        )
        expect(
            SideStagePolicy.scrollTarget(followLatest: false, anchorEntryId: "b") == "entry-b",
            "finished cards scroll to the anchored user turn"
        )

        let live = "child-session"
        expect(
            !SideStagePolicy.shouldAttachSession(
                sessionId: live,
                liveSessionIds: [live],
                childBusy: false
            ),
            "a live workspace session must not be session/load'd again"
        )
        expect(
            !SideStagePolicy.shouldAttachSession(
                sessionId: "other",
                liveSessionIds: [live],
                childBusy: true
            ),
            "do not attach any session while a child prompt is in flight"
        )
        expect(
            SideStagePolicy.shouldAttachSession(
                sessionId: "idle-session",
                liveSessionIds: [],
                childBusy: false
            ),
            "a finished historical session can be attached"
        )
        expect(
            !SideStagePolicy.shouldAttachSession(
                sessionId: "",
                liveSessionIds: [],
                childBusy: false
            ),
            "an empty session id is not attachable"
        )
        expect(
            !SideStagePolicy.shouldReloadOnShow(hasCachedRows: true),
            "showing a cached workspace stage must not reload its entire session"
        )
        expect(
            SideStagePolicy.shouldReloadOnShow(hasCachedRows: false),
            "an empty workspace stage still loads on show"
        )

        print("PASS: side stage policy")
    }
}
