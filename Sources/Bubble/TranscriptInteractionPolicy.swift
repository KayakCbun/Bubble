import Foundation

enum StartupTranscriptPolicy {
    static func isSetupCard(_ text: String, isSystem: Bool) -> Bool {
        isSystem && text.hasPrefix("Set up Bubble")
    }

    static func isTransientInternalError(_ text: String, isSystem: Bool) -> Bool {
        isSystem && text == "Internal error"
    }

    static func shouldPresentAfterConnection(hasCredentials: Bool) -> Bool {
        !hasCredentials
    }
}

enum ConversationBranchControlsPolicy {
    static func showsUserVariantSwitcher(variantCount: Int) -> Bool {
        variantCount > 1
    }

    static func showsAssistantBranchAction(hasSourceEntry: Bool, isStreaming: Bool) -> Bool {
        hasSourceEntry && !isStreaming
    }
}

enum TranscriptFollowPolicy {
    static let layoutSettleDelay: TimeInterval = 0.24

    static func followsContentHeightChange(isBusy: Bool) -> Bool {
        isBusy
    }

    /// Metadata persists (workspace anchors, etc.) bump the revision while idle.
    /// Those must not yank the main transcript to the bottom.
    static func followsRevisionChange(isBusy: Bool) -> Bool {
        isBusy
    }
}

enum FileChangeExpansionPolicy {
    /// Height animation invalidates the containing transcript layout on every
    /// animation frame, so file-tree expansion must be committed atomically.
    static let animatesTranscriptLayout = false
    /// A transcript-wide scroll correction creates a second visible hitch.
    /// Keep the card header anchored and reveal its files beneath it instead.
    static let requestsTranscriptFollow = false
}

enum TranscriptFollowTrigger {
    case contentHeightChanged
    case turnSettled
    case expansionSettled
}

enum TranscriptFollowTriggerPolicy {
    static func shouldRequestLatest(
        trigger: TranscriptFollowTrigger,
        followsLatest: Bool,
        isBusy: Bool
    ) -> Bool {
        guard followsLatest else { return false }
        switch trigger {
        case .contentHeightChanged:
            return TranscriptFollowPolicy.followsContentHeightChange(isBusy: isBusy)
        case .turnSettled:
            return !isBusy
        case .expansionSettled:
            return true
        }
    }
}

enum TranscriptTextSelectionPolicy {
    static func isEnabled(
        isHovering: Bool,
        primaryButtonPressed: Bool,
        pointerMoved: Bool = true,
        hasSettledSelection: Bool = false
    ) -> Bool {
        (isHovering && pointerMoved) || primaryButtonPressed || hasSettledSelection
    }
}

enum TranscriptStackPolicy {
    /// Small and medium transcripts are cheaper and substantially more stable
    /// when AppKit receives one settled document height. Reserve SwiftUI's lazy
    /// prefetch machinery for conversations large enough to need virtualization.
    static let lazyRowThreshold = 180

    static func usesLazyStack(rowCount: Int, sourceItemCount: Int) -> Bool {
        rowCount > lazyRowThreshold || sourceItemCount > lazyRowThreshold
    }
}

enum TranscriptScrollSequencePolicy {
    static func suppressesEventAfterProgrammaticScroll(
        isScrollWheel: Bool,
        beginsNewGesture: Bool,
        isDiscreteWheel: Bool,
        isDirectChange: Bool,
        hasMomentum: Bool
    ) -> Bool {
        guard isScrollWheel else { return false }
        if beginsNewGesture || isDiscreteWheel { return false }
        if isDirectChange, !hasMomentum { return false }
        return true
    }
}

enum TranscriptScrollRequest {
    case returnToEnd
    case returnControlVisibility
    case navigateToTurn
}

enum TranscriptScrollAnimationPolicy {
    /// A return-to-end animation keeps mutating the clip view after the chip is
    /// clicked, so the first wheel deltas can be overwritten. Make that jump
    /// immediate; spatial navigation within history can remain animated.
    static func shouldAnimate(_ request: TranscriptScrollRequest) -> Bool {
        switch request {
        case .returnToEnd, .returnControlVisibility:
            return false
        case .navigateToTurn:
            return true
        }
    }
}

enum TranscriptWheelScrollPolicy {
    private static let discreteStep: CGFloat = 24

    static func resolvedDelta(
        scrollingDeltaY: CGFloat,
        hasPreciseDeltas: Bool
    ) -> CGFloat {
        hasPreciseDeltas ? scrollingDeltaY : scrollingDeltaY * discreteStep
    }

    static func nextOrigin(
        current: CGFloat,
        scrollingDeltaY: CGFloat,
        hasPreciseDeltas: Bool,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        let delta = resolvedDelta(
            scrollingDeltaY: scrollingDeltaY,
            hasPreciseDeltas: hasPreciseDeltas
        )
        return min(maximum, max(minimum, current - delta))
    }
}

struct TranscriptWheelFrameStep: Equatable {
    let applied: CGFloat
    let remaining: CGFloat
}

enum TranscriptWheelFramePolicy {
    /// Keep one LazyVStack realization slice below a 60 fps frame budget on
    /// ProMotion displays while still allowing several thousand points/second.
    static func maximumStep(hasPreciseDeltas: Bool) -> CGFloat {
        hasPreciseDeltas ? 32 : 12
    }

    static func maximumPendingDelta(hasPreciseDeltas: Bool) -> CGFloat {
        maximumStep(hasPreciseDeltas: hasPreciseDeltas) * (hasPreciseDeltas ? 3 : 4)
    }

    static func queuedDelta(
        pending: CGFloat,
        incoming: CGFloat,
        maximumPendingDelta: CGFloat
    ) -> CGFloat {
        let combined: CGFloat
        if pending == 0 || incoming == 0 || (pending > 0) == (incoming > 0) {
            combined = pending + incoming
        } else {
            combined = incoming
        }
        return min(maximumPendingDelta, max(-maximumPendingDelta, combined))
    }

    static func nextFrame(pending: CGFloat, maximumStep: CGFloat) -> TranscriptWheelFrameStep {
        let applied = min(maximumStep, max(-maximumStep, pending))
        return TranscriptWheelFrameStep(applied: applied, remaining: pending - applied)
    }
}

enum TranscriptViewportReportPolicy {
    /// End-state and visible-row bookkeeping does not need ProMotion cadence.
    /// Keeping it to the product's 60 fps contract leaves the intervening
    /// refreshes available for AppKit and SwiftUI layout.
    static let minimumInterval: TimeInterval = 1.0 / 60.0
}

struct TranscriptFollowState: Equatable {
    private enum Mode: Equatable {
        case followingEnd
        case freeScrolling
        case returningToEnd
        case navigatingHistory(targetID: String)
        case followingTurn(targetID: String)
    }

    private var mode: Mode = .followingEnd

    var followsLatest: Bool { mode == .followingEnd || mode == .returningToEnd }
    var showsScrollToEnd: Bool {
        if case .followingEnd = mode { return false }
        if case .returningToEnd = mode { return false }
        if case .followingTurn = mode { return false }
        return true
    }
    var maintainsVisibleContent: Bool { mode == .freeScrolling }
    var historyNavigationTargetID: String? {
        guard case .navigatingHistory(let targetID) = mode else { return nil }
        return targetID
    }
    var followingTurnTargetID: String? {
        guard case .followingTurn(let targetID) = mode else { return nil }
        return targetID
    }

    func wouldChange(atEnd: Bool) -> Bool {
        followsLatest != atEnd
    }

    mutating func userNavigated(atEnd: Bool) {
        mode = atEnd ? .followingEnd : .freeScrolling
    }

    mutating func resumeAtEnd() {
        mode = .followingEnd
    }

    mutating func beginScrollToEnd() {
        mode = .returningToEnd
    }

    mutating func beginHistoryNavigation(targetID: String) {
        mode = .navigatingHistory(targetID: targetID)
    }

    mutating func beginFollowingTurn(targetID: String) {
        mode = .followingTurn(targetID: targetID)
    }

    @discardableResult
    mutating func finishFollowingTurn(targetID: String) -> Bool {
        guard case .followingTurn(let pendingID) = mode,
              pendingID == targetID else { return false }
        mode = .followingEnd
        return true
    }

    @discardableResult
    mutating func finishHistoryNavigation(targetID: String, atEnd: Bool) -> Bool {
        guard case .navigatingHistory(let pendingID) = mode,
              pendingID == targetID else { return false }
        mode = atEnd ? .followingEnd : .freeScrolling
        return true
    }

    /// Programmatic scroll animation can overlap AppKit's short user-event
    /// window. Ignore those stale intermediate positions until the viewport
    /// actually reaches the end.
    @discardableResult
    mutating func viewportChanged(atEnd: Bool, userDriven: Bool) -> Bool {
        if case .followingTurn = mode {
            guard userDriven else { return false }
            mode = atEnd ? .followingEnd : .freeScrolling
            return true
        }
        if case .navigatingHistory = mode {
            guard userDriven else { return false }
            mode = atEnd ? .followingEnd : .freeScrolling
            return true
        }
        if mode == .returningToEnd {
            if atEnd {
                mode = .followingEnd
                return true
            }
            guard userDriven else { return false }
            mode = .freeScrolling
            return true
        }
        guard userDriven, wouldChange(atEnd: atEnd) else { return false }
        userNavigated(atEnd: atEnd)
        return true
    }

    func shouldFollowRevision(isBusy: Bool) -> Bool {
        followsLatest && TranscriptFollowPolicy.followsRevisionChange(isBusy: isBusy)
    }
}

enum TranscriptTurnAlignmentPolicy {
    static let viewportAnchorY = 0.08
}

enum TranscriptViewportAnchorPolicy {
    static func visibleOrigin(
        anchorPosition: CGFloat,
        anchorOffset: CGFloat,
        visibleHeight: CGFloat,
        documentIsFlipped: Bool
    ) -> CGFloat {
        let desiredEdge = anchorPosition - anchorOffset
        return documentIsFlipped ? desiredEdge : desiredEdge - visibleHeight
    }
}

enum TranscriptExpansionPolicy {
    static func renderKey(containerExpanded: Bool, expandedChildIDs: [String]) -> String {
        let children = expandedChildIDs.sorted().joined(separator: ",")
        return "\(containerExpanded ? 1 : 0):\(children)"
    }
}
