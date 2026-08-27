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
                showingFilePreview: false,
                showingWorkspace: false,
                filePreviewWidth: 440,
                workspaceWidth: 760
            ) == 0,
            "closed stage adds no width"
        )
        expect(
            SideStagePolicy.width(
                showingFilePreview: true,
                showingWorkspace: true,
                filePreviewWidth: 440,
                workspaceWidth: 760
            ) == 440,
            "stacked markdown uses preview width"
        )
        expect(
            SideStagePolicy.width(
                showingFilePreview: false,
                showingWorkspace: true,
                filePreviewWidth: 440,
                workspaceWidth: 760
            ) == 760,
            "workspace session uses default transcript width"
        )
        expect(
            SideStagePolicy.showsWorkspaceTranscript(showingFilePreview: true, showingWorkspace: true) == false,
            "stacked markdown hides the workspace transcript"
        )
        expect(
            SideStagePolicy.canReturnToWorkspace(showingFilePreview: true, workspaceStacked: true),
            "markdown opened from a workspace session can return"
        )
        expect(
            !SideStagePolicy.canReturnToWorkspace(showingFilePreview: true, workspaceStacked: false),
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
            SideStagePresentationPolicy.waitsForContent(loadState: .ready, renderReady: false),
            "the placeholder remains while transcript rendering warms in the background"
        )
        expect(
            !SideStagePresentationPolicy.waitsForContent(loadState: .ready, renderReady: true),
            "the side stage may reveal only after both data and rendering are ready"
        )
        expect(
            SideStagePresentationPolicy.content(
                workspacePresented: false,
                phase: .ready
            ) == .hidden,
            "a closed workspace stage mounts neither placeholder nor transcript"
        )
        expect(
            SideStagePresentationPolicy.placeholderOpacity(coverVisible: true) == 1,
            "loading keeps the Bubble placeholder covering the extra card"
        )
        expect(
            SideStagePresentationPolicy.placeholderOpacity(coverVisible: false) == 0,
            "the placeholder fades out only after content has already been mounted"
        )
        expect(
            SideStagePresentationPolicy.mountsTranscript(phase: .placeholder) == false,
            "session transcript is not mounted while the extra card is still a placeholder"
        )
        expect(
            SideStagePresentationPolicy.mountsTranscript(phase: .ready),
            "session transcript mounts under the cover before the placeholder fades"
        )
        let paragraph = "一段需要被虚拟化的 workspace 助手输出。\n\n"
        let source = String(repeating: paragraph, count: 120) + "结尾"
        let chunks = WorkspaceTranscriptChunker.chunks(source, target: 500)
        expect(chunks.count > 4, "large assistant output is split into lazy render units")
        expect(chunks.joined() == source, "chunking preserves the exact assistant output")
        let referenceMarkdown = String(repeating: "See [the result][report].\n\n", count: 80)
            + "[report]: https://example.com/report"
        expect(
            WorkspaceTranscriptChunker.chunks(referenceMarkdown, target: 300) == [referenceMarkdown],
            "document-scoped reference Markdown remains one render unit"
        )
        let embeddedFence = String(repeating: "paragraph\n\n", count: 80)
            + "````text\nliteral ``` inside\n\nstill fenced\n````"
        expect(
            WorkspaceTranscriptChunker.chunks(embeddedFence, target: 300) == [embeddedFence],
            "all fenced Markdown remains one render unit"
        )
        for root in ["graph TD", "journey", "gantt", "pie", "mindmap", "gitGraph", "xychart-beta"] {
            let diagram = root + "\n\n" + String(repeating: "A --> B\n\n", count: 100)
            expect(
                WorkspaceTranscriptChunker.chunks(diagram, target: 300) == [diagram],
                "unfenced \(root) Mermaid remains one render unit"
            )
        }
        for root in ["mermaid journey", "mermaid_gantt", "Diagram: graph TD"] {
            let diagram = root + "\n\n" + String(repeating: "A --> B\n\n", count: 100)
            expect(
                WorkspaceTranscriptChunker.chunks(diagram, target: 300) == [diagram],
                "production-recognized \(root) Mermaid remains one render unit"
            )
        }
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
                showingFilePreview: true,
                workspaceStacked: true,
                showingWorkspace: true
            ) == .returnToWorkspace,
            "escape on stacked markdown returns to the session"
        )
        expect(
            SideStagePolicy.escapeAction(
                showingFilePreview: true,
                workspaceStacked: false,
                showingWorkspace: false
            ) == .closeStage,
            "escape on main markdown closes the stage"
        )
        expect(
            SideStagePolicy.escapeAction(
                showingFilePreview: false,
                workspaceStacked: false,
                showingWorkspace: true
            ) == .closeStage,
            "escape on the workspace session closes the stage"
        )
        let card = UUID()
        expect(SideStagePolicy.shouldToggleClosed(openCardId: card, tappedCardId: card), "same card closes")
        expect(!SideStagePolicy.shouldToggleClosed(openCardId: card, tappedCardId: UUID()), "other card replaces")
        expect(
            SideStagePolicy.shouldFollowNewWorkspaceRun(
                currentMountPath: "/mount/a",
                showingFilePreview: false,
                nextMountPath: "/mount/b"
            ),
            "an open workspace stage follows a run started in another mount"
        )
        expect(
            !SideStagePolicy.shouldFollowNewWorkspaceRun(
                currentMountPath: nil,
                showingFilePreview: false,
                nextMountPath: "/mount/b"
            ),
            "a new workspace run does not open a stage the user had closed"
        )
        expect(
            !SideStagePolicy.shouldFollowNewWorkspaceRun(
                currentMountPath: "/mount/a",
                showingFilePreview: true,
                nextMountPath: "/mount/b"
            ),
            "a new workspace run does not replace a markdown document the user is reading"
        )
        expect(
            !SideStagePolicy.shouldFollowNewWorkspaceRun(
                currentMountPath: "/mount/a",
                showingFilePreview: false,
                nextMountPath: "/mount/a"
            ),
            "updates from the currently displayed mount stay in the existing stage"
        )
        expect(
            SideStagePolicy.preferredWorkspaceSessionId(
                cardSessionId: "session-card",
                mountedSessionId: "session-mount"
            ) == "session-card",
            "a run card's exact workspace session remains authoritative"
        )
        expect(
            SideStagePolicy.preferredWorkspaceSessionId(
                cardSessionId: nil,
                mountedSessionId: "session-b"
            ) == "session-b",
            "a reopened mount uses that mount's remembered session"
        )
        expect(
            SideStagePolicy.preferredWorkspaceSessionId(
                cardSessionId: nil,
                mountedSessionId: nil
            ) == nil,
            "a brand-new mount never inherits the previously displayed workspace session"
        )
        expect(
            SideStagePolicy.shouldRebindResolvedWorkspaceSession(
                currentMountPath: "/mount/b",
                currentRunId: "run-b",
                showingFilePreview: false,
                resolvedMountPath: "/mount/b",
                resolvedRunId: "run-b"
            ),
            "a followed workspace stage rebinds when its final session is resolved"
        )
        expect(
            !SideStagePolicy.shouldRebindResolvedWorkspaceSession(
                currentMountPath: "/mount/b",
                currentRunId: "run-old",
                showingFilePreview: false,
                resolvedMountPath: "/mount/b",
                resolvedRunId: "run-b"
            ),
            "a late session resolution cannot replace a newer run"
        )
        expect(
            !SideStagePolicy.shouldRebindResolvedWorkspaceSession(
                currentMountPath: "/mount/b",
                currentRunId: "run-b",
                showingFilePreview: true,
                resolvedMountPath: "/mount/b",
                resolvedRunId: "run-b"
            ),
            "session resolution does not steal a markdown document opened meanwhile"
        )
        expect(
            SideStagePolicy.keepWorkspaceWhenOpeningFilePreview(fromWorkspacePane: true),
            "links inside the workspace pane keep the session stacked"
        )
        expect(
            !SideStagePolicy.keepWorkspaceWhenOpeningFilePreview(fromWorkspacePane: false),
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
