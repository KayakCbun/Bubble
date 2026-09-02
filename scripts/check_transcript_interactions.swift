import Foundation

private var failures: [String] = []

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}

@main
private enum TranscriptInteractionCheck {
    static func main() {
        expect(
            StartupTranscriptPolicy.isSetupCard("Set up Bubble\nPi — not found", isSystem: true),
            "a persisted setup card must be recognized after relaunch"
        )
        expect(
            !StartupTranscriptPolicy.isSetupCard("Bubble is ready.", isSystem: true),
            "ordinary system messages must survive startup cleanup"
        )
        expect(
            !StartupTranscriptPolicy.isSetupCard("Set up Bubble in this repo", isSystem: false),
            "user-authored messages with the setup prefix must survive relaunch"
        )
        expect(
            StartupTranscriptPolicy.isTransientInternalError("Internal error", isSystem: true),
            "a bare transient runtime failure must be discarded after relaunch"
        )
        expect(
            !StartupTranscriptPolicy.isTransientInternalError("Internal error", isSystem: false),
            "user-authored text matching a runtime failure must survive relaunch"
        )
        expect(
            !StartupTranscriptPolicy.isTransientInternalError("Internal error: details", isSystem: true),
            "diagnostic system messages with useful detail must survive relaunch"
        )
        expect(
            StartupTranscriptPolicy.shouldPresentAfterConnection(hasCredentials: false),
            "a connected runtime still needs setup guidance when no provider is signed in"
        )
        expect(
            !StartupTranscriptPolicy.shouldPresentAfterConnection(hasCredentials: true),
            "a ready signed-in runtime must not restore the stale setup card"
        )
        expect(
            !ConversationBranchControlsPolicy.showsUserVariantSwitcher(variantCount: 1),
            "a user message with no alternatives must not show a branch action row"
        )
        expect(
            ConversationBranchControlsPolicy.showsUserVariantSwitcher(variantCount: 2),
            "existing branch variants keep their stable inline switcher"
        )
        expect(
            ConversationBranchControlsPolicy.showsAssistantBranchAction(hasSourceEntry: true, isStreaming: false),
            "a persisted assistant response must always show its branch action"
        )
        expect(
            !ConversationBranchControlsPolicy.showsAssistantBranchAction(hasSourceEntry: true, isStreaming: true),
            "a streaming assistant response must wait before offering a branch action"
        )
        expect(
            !TranscriptFollowPolicy.followsContentHeightChange(isBusy: false),
            "idle hover geometry must not force the transcript to the bottom"
        )
        expect(
            TranscriptFollowPolicy.followsContentHeightChange(isBusy: true),
            "streaming content growth should continue following the latest response"
        )
        expect(
            !TranscriptTextSelectionPolicy.isEnabled(isHovering: false, primaryButtonPressed: false),
            "offscreen transcript rows must not retain SwiftUI selection overlays"
        )
        expect(
            TranscriptTextSelectionPolicy.isEnabled(
                isHovering: true,
                primaryButtonPressed: false,
                pointerMoved: true
            ),
            "hovering a transcript row enables quote selection"
        )
        expect(
            !TranscriptTextSelectionPolicy.isEnabled(
                isHovering: true,
                primaryButtonPressed: false,
                pointerMoved: false
            ),
            "scrolling content under a stationary pointer must not mount selection overlays"
        )
        expect(
            TranscriptTextSelectionPolicy.isEnabled(isHovering: false, primaryButtonPressed: true),
            "selection remains enabled while a drag leaves its source row"
        )
        expect(
            TranscriptTextSelectionPolicy.isEnabled(
                isHovering: false,
                primaryButtonPressed: false,
                pointerMoved: false,
                hasSettledSelection: true
            ),
            "a settled quote selection must survive while the pointer moves from text to Add to chat"
        )
        expect(
            !TranscriptStackPolicy.usesLazyStack(rowCount: 97, sourceItemCount: 97),
            "ordinary mixed transcripts avoid SwiftUI lazy-prefetch stalls"
        )
        expect(
            TranscriptStackPolicy.usesLazyStack(rowCount: 120, sourceItemCount: 1_520),
            "very large transcripts retain row virtualization"
        )
        expect(
            !TranscriptFollowPolicy.followsRevisionChange(isBusy: false),
            "idle transcript metadata writes must not yank the main conversation to the bottom"
        )
        expect(
            TranscriptFollowPolicy.followsRevisionChange(isBusy: true),
            "a live main turn still follows revision while streaming"
        )
        expect(
            !FileChangeExpansionPolicy.animatesTranscriptLayout,
            "changed-file expansion must not animate the entire transcript layout"
        )
        expect(
            !FileChangeExpansionPolicy.requestsTranscriptFollow,
            "changed-file expansion should preserve its viewport anchor"
        )
        expect(
            !TranscriptScrollSequencePolicy.suppressesEventAfterProgrammaticScroll(
                isScrollWheel: true,
                beginsNewGesture: false,
                isDiscreteWheel: false,
                isDirectChange: true,
                hasMomentum: false
            ),
            "direct wheel movement immediately interrupts a scroll-to-end animation"
        )
        expect(
            TranscriptScrollSequencePolicy.suppressesEventAfterProgrammaticScroll(
                isScrollWheel: true,
                beginsNewGesture: false,
                isDiscreteWheel: false,
                isDirectChange: false,
                hasMomentum: true
            ),
            "momentum tail events from the prior gesture stay suppressed"
        )
        expect(
            !TranscriptScrollAnimationPolicy.shouldAnimate(.returnToEnd),
            "returning to the transcript end must not keep an animation alive against the next wheel event"
        )
        expect(
            !TranscriptScrollAnimationPolicy.shouldAnimate(.returnControlVisibility),
            "showing the return control must not animate the entire scroll container"
        )
        expect(
            TranscriptScrollAnimationPolicy.shouldAnimate(.navigateToTurn),
            "ordinary turn navigation keeps its spatial transition"
        )
        expect(
            TranscriptWheelScrollPolicy.nextOrigin(
                current: 100,
                scrollingDeltaY: 20,
                hasPreciseDeltas: true,
                minimum: 0,
                maximum: 200
            ) == 80,
            "a precise upward wheel delta moves the transcript away from the bottom immediately"
        )
        expect(
            TranscriptWheelScrollPolicy.nextOrigin(
                current: 190,
                scrollingDeltaY: -20,
                hasPreciseDeltas: true,
                minimum: 0,
                maximum: 200
            ) == 200,
            "direct wheel movement stays inside the document bounds"
        )
        expect(
            TranscriptWheelScrollPolicy.nextOrigin(
                current: 100,
                scrollingDeltaY: 1,
                hasPreciseDeltas: false,
                minimum: 0,
                maximum: 200
            ) == 76,
            "one discrete mouse-wheel notch has enough distance to interpolate visibly"
        )
        expect(
            TranscriptWheelCapturePolicy.shouldCapture(deltaX: 0, deltaY: 1),
            "a vertical mouse-wheel packet is captured at the transcript boundary"
        )
        expect(
            !TranscriptWheelCapturePolicy.shouldCapture(deltaX: 12, deltaY: 1),
            "a nested horizontal scroller keeps a horizontal gesture"
        )
        expect(
            !TranscriptWheelCapturePolicy.shouldCapture(deltaX: 8, deltaY: 8),
            "an equal diagonal gesture stays available to a nested horizontal scroller"
        )
        expect(
            !TranscriptWheelCapturePolicy.shouldCapture(deltaX: 0, deltaY: 0),
            "a zero-delta wheel packet is not consumed"
        )
        expect(
            TranscriptNestedVerticalScrollPolicy.shouldDeferToNestedScroller(
                documentHeight: 400,
                clipHeight: 180,
                identifier: nil
            ),
            "an overflowing nested vertical scroller keeps the wheel"
        )
        expect(
            !TranscriptNestedVerticalScrollPolicy.shouldDeferToNestedScroller(
                documentHeight: 80,
                clipHeight: 180,
                identifier: nil
            ),
            "a nested scroller that fits still falls through to the transcript"
        )
        expect(
            TranscriptNestedVerticalScrollPolicy.shouldDeferToNestedScroller(
                documentHeight: 80,
                clipHeight: 180,
                identifier: TranscriptNestedVerticalScrollPolicy.recordNotesIdentifier
            ),
            "Record notes keep the wheel while the pointer is over the card"
        )
        expect(
            !TranscriptCommandCompletionPolicy.shouldApply(
                isScrollToEnd: true,
                issuedUserScrollGeneration: 4,
                currentUserScrollGeneration: 5
            ),
            "a physical wheel gesture supersedes a pending scroll-to-end completion"
        )
        expect(
            TranscriptCommandCompletionPolicy.shouldApply(
                isScrollToEnd: false,
                issuedUserScrollGeneration: 4,
                currentUserScrollGeneration: 5
            ),
            "ordinary command completion is independent of wheel generations"
        )
        expect(
            TranscriptWheelFramePolicy.queuedDelta(
                pending: 200,
                incoming: 400,
                maximumPendingDelta: TranscriptWheelFramePolicy.maximumPendingDelta(
                    hasPreciseDeltas: true
                )
            ) == 96,
            "same-direction trackpad packets coalesce without creating a long post-input tail"
        )
        expect(
            TranscriptWheelFramePolicy.queuedDelta(
                pending: 200,
                incoming: -40,
                maximumPendingDelta: 96
            ) == -40,
            "a direction reversal discards stale queued motion immediately"
        )
        expect(
            TranscriptWheelFramePolicy.nextFrame(
                pending: 600,
                maximumStep: TranscriptWheelFramePolicy.maximumStep(hasPreciseDeltas: true)
            ) == TranscriptWheelFrameStep(applied: 32, remaining: 568),
            "one display refresh cannot realize an unbounded LazyVStack jump"
        )
        expect(
            TranscriptWheelFramePolicy.nextFrame(
                pending: -600,
                maximumStep: TranscriptWheelFramePolicy.maximumStep(hasPreciseDeltas: true)
            ) == TranscriptWheelFrameStep(applied: -32, remaining: -568),
            "the per-frame movement bound is symmetric in both directions"
        )
        expect(
            TranscriptWheelFramePolicy.nextFrame(pending: 40, maximumStep: 96)
                == TranscriptWheelFrameStep(applied: 40, remaining: 0),
            "a small direct gesture is fully visible on the first refresh"
        )
        expect(
            TranscriptWheelFramePolicy.nextFrame(
                pending: 24,
                maximumStep: TranscriptWheelFramePolicy.maximumStep(hasPreciseDeltas: false)
            ) == TranscriptWheelFrameStep(applied: 8, remaining: 16),
            "one mouse-wheel notch is interpolated across more than one display refresh"
        )
        expect(
            TranscriptWheelFramePolicy.maximumPendingDelta(hasPreciseDeltas: false) == 32,
            "mouse interpolation remains bounded to four display refreshes"
        )
        expect(
            TranscriptViewportReportPolicy.minimumInterval >= 1.0 / 60.0,
            "viewport bookkeeping cannot run more often than the 60 fps UI contract"
        )
        var follow = TranscriptFollowState()
        expect(follow.followsLatest, "a transcript starts pinned to the live edge")
        expect(!follow.showsScrollToEnd, "the jump chip stays hidden while already at the end")
        expect(!follow.wouldChange(atEnd: true), "repeated end notifications stay off the render hot path")
        follow.userNavigated(atEnd: false)
        expect(!follow.followsLatest, "an upward user scroll immediately disables live follow")
        expect(follow.showsScrollToEnd, "leaving the end reveals a direct jump back to the live edge")
        expect(!follow.wouldChange(atEnd: false), "repeated free-scroll notifications stay off the render hot path")
        expect(!follow.shouldFollowRevision(isBusy: true), "streaming cannot yank a history reader back to the end")
        follow.beginScrollToEnd()
        expect(follow.followsLatest, "a requested end jump immediately re-arms live following")
        expect(!follow.showsScrollToEnd, "a requested end jump dismisses the chip")
        expect(
            !follow.viewportChanged(atEnd: false, userDriven: false),
            "programmatic intermediate positions cannot cancel an in-flight end jump"
        )
        expect(follow.followsLatest, "an intermediate animated position stays committed to the end jump")
        expect(
            follow.viewportChanged(atEnd: true, userDriven: false),
            "observing the real end confirms a programmatic jump without requiring a user event"
        )
        follow.userNavigated(atEnd: false)
        follow.beginScrollToEnd()
        expect(
            follow.viewportChanged(atEnd: false, userDriven: true),
            "a fresh user gesture can interrupt an in-flight end jump"
        )
        expect(follow.showsScrollToEnd, "interrupting the end jump restores the chip")
        follow.beginHistoryNavigation(targetID: "turn-42")
        expect(
            follow.historyNavigationTargetID == "turn-42",
            "the requested history target stays addressable until its row is mounted"
        )
        expect(!follow.followsLatest, "a history jump does not resume live following")
        expect(
            !follow.maintainsVisibleContent,
            "visible-anchor restoration stays suspended while a history target is settling"
        )
        expect(follow.showsScrollToEnd, "a history jump keeps the direct return-to-end affordance")
        expect(
            !follow.finishHistoryNavigation(targetID: "stale-turn", atEnd: false),
            "a stale target cannot settle a newer history jump"
        )
        expect(
            follow.finishHistoryNavigation(targetID: "turn-42", atEnd: false),
            "the matching mounted target settles history navigation"
        )
        expect(follow.historyNavigationTargetID == nil, "settling clears the pending history target")
        expect(
            follow.maintainsVisibleContent,
            "settled history browsing resumes dynamic-height anchor preservation"
        )
        follow.userNavigated(atEnd: true)
        expect(follow.followsLatest, "returning to the end re-arms live follow")
        follow.userNavigated(atEnd: false)
        follow.resumeAtEnd()
        expect(follow.followsLatest, "sending a new user turn deliberately resumes live follow")
        expect(!follow.showsScrollToEnd, "resuming the live edge dismisses the jump chip")
        follow.beginFollowingTurn(targetID: "user-turn")
        expect(follow.followingTurnTargetID == "user-turn", "a sent user turn becomes the viewport anchor")
        expect(!follow.followsLatest, "a sent user turn is aligned near the top instead of following the bottom")
        expect(!follow.viewportChanged(atEnd: false, userDriven: false), "programmatic turn alignment keeps its anchor")
        expect(
            !follow.finishFollowingTurn(targetID: "stale-user-turn"),
            "a stale alignment completion cannot release the current sent-turn anchor"
        )
        expect(
            follow.finishFollowingTurn(targetID: "user-turn"),
            "the initial sent-turn alignment hands subsequent streaming growth back to live follow"
        )
        expect(follow.followsLatest, "long reasoning and final output continue following the live edge")
        expect(
            TranscriptFollowTriggerPolicy.shouldRequestLatest(
                trigger: .contentHeightChanged,
                followsLatest: follow.followsLatest,
                isBusy: true
            ),
            "streaming thought height changes request another bottom alignment"
        )
        expect(
            TranscriptFollowTriggerPolicy.shouldRequestLatest(
                trigger: .turnSettled,
                followsLatest: follow.followsLatest,
                isBusy: false
            ),
            "turn completion performs a settled final bottom alignment"
        )
        expect(
            !TranscriptFollowTriggerPolicy.shouldRequestLatest(
                trigger: .turnSettled,
                followsLatest: follow.followsLatest,
                isBusy: true
            ),
            "starting a turn does not masquerade as final layout settlement"
        )
        expect(
            !TranscriptFollowTriggerPolicy.shouldRequestLatest(
                trigger: .expansionSettled,
                followsLatest: follow.followsLatest,
                isBusy: false
            ),
            "row-local disclosure changes must not request a transcript-wide follow"
        )
        expect(
            !TranscriptFollowTriggerPolicy.shouldRequestLatest(
                trigger: .expansionSettled,
                followsLatest: false,
                isBusy: false
            ),
            "collapsing a thought cannot yank a user who scrolled up back to the bottom"
        )
        follow.beginFollowingTurn(targetID: "manual-turn")
        expect(follow.viewportChanged(atEnd: false, userDriven: true), "manual scrolling releases the sent-turn anchor")
        expect(TranscriptTurnAlignmentPolicy.viewportAnchorY == 0.08, "sent messages keep breathing room above them")
        expect(
            TranscriptViewportAnchorPolicy.visibleOrigin(
                anchorPosition: 480,
                anchorOffset: -20,
                visibleHeight: 300,
                documentIsFlipped: true
            ) == 500,
            "a row growing above the viewport preserves the visible row offset"
        )
        expect(
            TranscriptViewportAnchorPolicy.visibleOrigin(
                anchorPosition: 480,
                anchorOffset: 20,
                visibleHeight: 300,
                documentIsFlipped: false
            ) == 160,
            "non-flipped scroll documents preserve the same anchor offset"
        )
        expect(
            TranscriptRowInteractionPolicy.usesRowLocalState,
            "thought and tool disclosure state is owned by a stable row host"
        )
        expect(
            TranscriptRowInteractionPolicy.isOpen(isLive: true, isExpanded: false),
            "a live thought remains open while its row streams"
        )
        expect(
            !TranscriptRowInteractionPolicy.canToggle(isLive: true),
            "a live thought cannot be collapsed mid-stream"
        )
        expect(
            TranscriptRowInteractionPolicy.invalidatedRowIDs(
                changedRowID: "tool-b",
                visibleRowIDs: ["thought-a", "tool-b", "group-c"]
            ) == ["tool-b"],
            "a disclosure mutation invalidates only its own stable row"
        )
        expect(
            TranscriptRowInteractionPolicy.invalidatedRowIDs(
                changedRowID: "stale",
                visibleRowIDs: ["thought-a", "tool-b"]
            ).isEmpty,
            "stale disclosure callbacks do not invalidate the transcript"
        )
        expect(
            !TranscriptRowInteractionPolicy.animatesTranscriptLayout,
            "completed row expansion commits a final height without layout animation"
        )
        expect(
            !TranscriptRowInteractionPolicy.requestsTranscriptFollow,
            "completed row expansion does not request transcript-wide scrolling"
        )
        if !failures.isEmpty {
            for failure in failures {
                FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
            }
            exit(1)
        }
        print("PASS: transcript interaction regressions")
    }
}
