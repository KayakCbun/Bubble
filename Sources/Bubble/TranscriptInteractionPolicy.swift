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
    }

    private var mode: Mode = .followingEnd

    var followsLatest: Bool { mode != .freeScrolling }
    var showsScrollToEnd: Bool { mode == .freeScrolling }

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

    /// Programmatic scroll animation can overlap AppKit's short user-event
    /// window. Ignore those stale intermediate positions until the viewport
    /// actually reaches the end.
    @discardableResult
    mutating func viewportChanged(atEnd: Bool, userDriven: Bool) -> Bool {
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
