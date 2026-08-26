import Foundation

enum StartupTranscriptPolicy {
    static func isSetupCard(_ text: String, isSystem: Bool) -> Bool {
        isSystem && text.hasPrefix("Set up Bubble")
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
    static func followsContentHeightChange(isBusy: Bool) -> Bool {
        isBusy
    }

    /// Metadata persists (workspace anchors, etc.) bump the revision while idle.
    /// Those must not yank the main transcript to the bottom.
    static func followsRevisionChange(isBusy: Bool) -> Bool {
        isBusy
    }
}

struct TranscriptFollowState: Equatable {
    private enum Mode: Equatable {
        case followingEnd
        case freeScrolling
        case returningToEnd
        case navigatingHistory(targetID: String)
    }

    private var mode: Mode = .followingEnd

    var followsLatest: Bool { mode == .followingEnd || mode == .returningToEnd }
    var showsScrollToEnd: Bool {
        if case .followingEnd = mode { return false }
        if case .returningToEnd = mode { return false }
        return true
    }
    var maintainsVisibleContent: Bool { mode == .freeScrolling }
    var historyNavigationTargetID: String? {
        guard case .navigatingHistory(let targetID) = mode else { return nil }
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
