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
            !SideStagePolicy.shouldReloadWorkspacePaneOnResume(.loading),
            "resuming presentation does not restart an in-flight workspace load"
        )
        expect(
            SideStagePolicy.shouldReloadWorkspacePaneOnResume(.fallback),
            "a fallback workspace pane can refresh after presentation resumes"
        )
        expect(
            SideStagePresentationPolicy.content(
                workspacePresented: true,
                phase: .placeholder
            ) == .placeholder,
            "opening a workspace stage paints the lightweight placeholder first"
        )
        expect(
            SideStagePresentationPolicy.content(
                workspacePresented: true,
                phase: .ready
            ) == .transcript,
            "workspace transcript mounts only after the panel settles"
        )
        expect(
            SideStagePresentationPolicy.content(
                workspacePresented: true,
                phase: .waitingForContent
            ) == .placeholder,
            "the Bubble placeholder remains until workspace content is available"
        )
        expect(
            SideStagePresentationPolicy.content(
                workspacePresented: false,
                phase: .ready
            ) == .hidden,
            "a closed workspace stage mounts neither placeholder nor transcript"
        )
        expect(
            !SideStageChromePolicy.waitsForPanelSettleToRevealChrome(),
            "the extra card fades immediately instead of waiting for the panel spring"
        )
        expect(
            SideStageChromePolicy.opensHidden(wasPresented: false),
            "opening from collapsed inserts chrome at opacity 0 so it can fade immediately"
        )
        expect(
            !SideStageChromePolicy.opensHidden(wasPresented: true),
            "replacing an already-open stage keeps chrome visible"
        )
        expect(
            SideStageChromePolicy.shouldFadeOutBeforeCollapse(chromeVisible: true, presented: true),
            "a visible extra card fades out before the conversation slides back"
        )
        expect(
            !SideStageChromePolicy.shouldFadeOutBeforeCollapse(chromeVisible: false, presented: true),
            "closing during the slide skips a fade that never started"
        )
        expect(
            !SideStageChromePolicy.shouldFadeOutBeforeCollapse(chromeVisible: true, presented: false),
            "a collapsed stage has no chrome to fade"
        )
        expect(SideStageChromePolicy.opacity(visible: false) == 0, "hidden chrome is fully transparent")
        expect(SideStageChromePolicy.opacity(visible: true) == 1, "settled chrome is fully opaque")
        expect(
            SideStageChromePolicy.hitPreviewWidth(chromeVisible: false, previewWidth: 560) == 0,
            "empty reserved space is not a card for hit testing"
        )
        expect(
            SideStageChromePolicy.hitPreviewWidth(chromeVisible: true, previewWidth: 560) == 560,
            "visible chrome receives clicks on the extra card"
        )
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
        let turnRows = [
            WorkspaceTurnRow(id: "user-b", sourceEntryId: "b", kind: .user),
            WorkspaceTurnRow(id: "thought-b", sourceEntryId: "assistant-b", kind: .thought),
            WorkspaceTurnRow(id: "assistant-b", sourceEntryId: "assistant-b", kind: .assistant),
            WorkspaceTurnRow(id: "user-c", sourceEntryId: "c", kind: .user),
            WorkspaceTurnRow(id: "assistant-c", sourceEntryId: "assistant-c", kind: .assistant),
        ]
        expect(
            SideStagePolicy.runRange(anchorEntryId: "b", rows: turnRows) == 0..<3,
            "a completed card displays only its anchored workspace run"
        )
        expect(
            !WorkspaceRunLifecyclePolicy.acceptsCompletion(
                expectedGeneration: 4,
                currentGeneration: 5,
                expectedRunId: "run-old",
                activeRunId: nil
            ),
            "a workspace completion from before /new cannot enter the new main session"
        )
        expect(
            WorkspaceRunLifecyclePolicy.acceptsCompletion(
                expectedGeneration: 5,
                currentGeneration: 5,
                expectedRunId: "run-current",
                activeRunId: "run-current"
            ),
            "the current workspace run may complete"
        )
        expect(
            !WorkspaceRunLifecyclePolicy.shouldPrepareSession(childBusy: true),
            "a queued follow-up never attaches the live child session"
        )
        expect(
            !WorkspaceRunLifecyclePolicy.acceptsStreamUpdate(
                routedSessionId: "child-old",
                activeChildSessionId: "child-new",
                childBusy: true
            ),
            "late chunks from an old main session cannot enter the current workspace run"
        )
        expect(
            WorkspaceRunLifecyclePolicy.acceptsStreamUpdate(
                routedSessionId: "child-new",
                activeChildSessionId: "child-new",
                childBusy: true
            ),
            "the active child session continues streaming into its run"
        )
        expect(
            SideStagePolicy.scrollTarget(
                followLatest: false,
                anchorEntryId: "b",
                rows: turnRows
            ) == "assistant-b",
            "finished cards scroll to the end of the anchored turn's assistant output"
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
        expect(
            !SideStagePolicy.shouldFallbackWorkspaceLoad(elapsed: 2.49),
            "local workspace loading keeps its short grace period"
        )
        expect(
            SideStagePolicy.shouldFallbackWorkspaceLoad(elapsed: 2.5),
            "workspace loading settles to local card data before three seconds"
        )
        expect(
            SideStagePolicy.acceptsWorkspaceUpdate(stageRunId: "run-a", incomingRunId: "run-a"),
            "the selected run accepts its own stream"
        )
        expect(
            !SideStagePolicy.acceptsWorkspaceUpdate(stageRunId: nil, incomingRunId: "run-b"),
            "a legacy card cannot absorb a newer run's stream"
        )
        expect(
            !SideStagePolicy.acceptsWorkspaceUpdate(stageRunId: "run-a", incomingRunId: "run-b"),
            "a historical run cannot absorb another run's stream"
        )
        expect(
            SideStagePolicy.paneSeed(.init(
                currentSessionId: "shared",
                nextSessionId: "shared",
                currentCardId: card,
                nextCardId: card,
                hasCurrentRows: true,
                hasRunRows: false,
                cacheIsFresh: false,
                selectedAnchorIsCached: false,
                isLive: true
            )) == .current,
            "an already-open live card keeps its streamed rows"
        )
        expect(
            SideStagePolicy.paneSeed(.init(
                currentSessionId: "shared",
                nextSessionId: "shared",
                currentCardId: UUID(),
                nextCardId: card,
                hasCurrentRows: true,
                hasRunRows: false,
                cacheIsFresh: true,
                selectedAnchorIsCached: false,
                isLive: true
            )) == .card,
            "switching to a new live run starts from that card's own user boundary"
        )
        expect(
            SideStagePolicy.paneSeed(.init(
                currentSessionId: "shared",
                nextSessionId: "shared",
                currentCardId: UUID(),
                nextCardId: card,
                hasCurrentRows: true,
                hasRunRows: true,
                cacheIsFresh: false,
                selectedAnchorIsCached: false,
                isLive: true
            )) == .run,
            "returning to a live run restores its streamed pane buffer"
        )
        expect(
            SideStagePolicy.paneSeed(.init(
                currentSessionId: "shared",
                nextSessionId: "shared",
                currentCardId: UUID(),
                nextCardId: card,
                hasCurrentRows: true,
                hasRunRows: true,
                cacheIsFresh: false,
                selectedAnchorIsCached: false,
                isLive: false
            )) == .run,
            "a completed card restores only its run-scoped rows"
        )
        expect(
            SideStagePolicy.paneSeed(.init(
                currentSessionId: "shared",
                nextSessionId: "shared",
                currentCardId: UUID(),
                nextCardId: card,
                hasCurrentRows: true,
                hasRunRows: false,
                cacheIsFresh: true,
                selectedAnchorIsCached: true,
                isLive: false
            )) == .current,
            "switching cards in one session keeps the authoritative rows"
        )
        expect(
            SideStagePolicy.paneSeed(.init(
                currentSessionId: "other",
                nextSessionId: "shared",
                currentCardId: UUID(),
                nextCardId: card,
                hasCurrentRows: true,
                hasRunRows: false,
                cacheIsFresh: true,
                selectedAnchorIsCached: true,
                isLive: false
            )) == .cached,
            "reopening a session uses its cached transcript"
        )
        expect(
            SideStagePolicy.paneSeed(.init(
                currentSessionId: nil,
                nextSessionId: "shared",
                currentCardId: nil,
                nextCardId: card,
                hasCurrentRows: false,
                hasRunRows: false,
                cacheIsFresh: false,
                selectedAnchorIsCached: false,
                isLive: false
            )) == .loading,
            "a first open shows stable loading instead of card-derived rows"
        )
        expect(
            SideStagePolicy.paneSeed(.init(
                currentSessionId: "shared",
                nextSessionId: "shared",
                currentCardId: UUID(),
                nextCardId: card,
                hasCurrentRows: true,
                hasRunRows: false,
                cacheIsFresh: false,
                selectedAnchorIsCached: true,
                isLive: false
            )) == .loading,
            "a session-invalidated cache never masquerades as authoritative"
        )
        expect(
            SideStagePolicy.paneSeed(.init(
                currentSessionId: "shared",
                nextSessionId: "shared",
                currentCardId: UUID(),
                nextCardId: card,
                hasCurrentRows: true,
                hasRunRows: false,
                cacheIsFresh: true,
                selectedAnchorIsCached: false,
                isLive: false
            )) == .loading,
            "a fresh cache missing the selected anchor loads atomically"
        )

        print("PASS: side stage policy")
    }
}
