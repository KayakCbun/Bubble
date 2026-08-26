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
            !SessionSwitchLoadingPolicy.usesMask(
                sourceItemCount: 40,
                textBytes: 12_000,
                mediaCount: 0
            ),
            "short sessions must keep instant tab switching without a loading flash"
        )
        expect(
            SessionSwitchLoadingPolicy.usesMask(
                sourceItemCount: 240,
                textBytes: 12_000,
                mediaCount: 0
            ),
            "long sessions must show a loading mask before their transcript is mounted"
        )
        expect(
            SessionSwitchLoadingPolicy.usesMask(
                sourceItemCount: 12,
                textBytes: 100_000,
                mediaCount: 0
            ),
            "a few very large messages must still count as a long session"
        )
        expect(
            SessionSwitchLoadingPolicy.usesMask(
                sourceItemCount: 8,
                textBytes: 8_000,
                mediaCount: 6
            ),
            "media-heavy sessions must show loading before image views mount"
        )
        expect(
            !TranscriptFollowPolicy.followsRevisionChange(isBusy: false),
            "idle transcript metadata writes must not yank the main conversation to the bottom"
        )
        expect(
            TranscriptFollowPolicy.followsRevisionChange(isBusy: true),
            "a live main turn still follows revision while streaming"
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
        let collapsed = TranscriptExpansionPolicy.renderKey(
            containerExpanded: false,
            expandedChildIDs: []
        )
        let expanded = TranscriptExpansionPolicy.renderKey(
            containerExpanded: true,
            expandedChildIDs: []
        )
        expect(collapsed != expanded, "expanding a thought or tool must invalidate its equatable row")
        expect(
            TranscriptExpansionPolicy.renderKey(containerExpanded: true, expandedChildIDs: ["tool-b", "tool-a"])
                == TranscriptExpansionPolicy.renderKey(containerExpanded: true, expandedChildIDs: ["tool-a", "tool-b"]),
            "group expansion keys are stable regardless of Set iteration order"
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
