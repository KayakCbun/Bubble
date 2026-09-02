import Foundation

enum OverlayPresentationPolicy {
    static let showDuration: TimeInterval = 0.14
    static let hideDuration: TimeInterval = 0.10
    static let nonCriticalWorkDelay: TimeInterval = 0.30
    static let verticalOffset: CGFloat = 14
    static let stablePreflightFrames = 2

    /// Visibility transitions belong to the presentation layer. The physical
    /// NSWindow remains at its final resting frame so SwiftUI never relays out
    /// the transcript while Bubble appears or disappears.
    static func windowFrame(resting: CGRect, visible: Bool) -> CGRect {
        resting
    }

    static func shouldBegin(
        layoutSessionID: UUID?,
        selectedSessionID: UUID,
        targetFramePending: Bool,
        geometryAnimating: Bool,
        transcriptRestorePending: Bool
    ) -> Bool {
        layoutSessionID == selectedSessionID
            && !targetFramePending
            && !geometryAnimating
            && !transcriptRestorePending
    }

    static func defersNonCriticalWork(isTransitioning: Bool) -> Bool {
        isTransitioning
    }
}

enum ComposerFocusPolicy {
    static let submissionRestoreDelay: TimeInterval = 0.02

    /// Stream rendering may pause for ordinary panel geometry changes without
    /// making the composer unavailable. Only window visibility transitions
    /// suspend keyboard focus.
    static func isSuspended(
        panelVisible: Bool,
        presentationTransitioning: Bool
    ) -> Bool {
        !panelVisible || presentationTransitioning
    }

    static func shouldRequestFocus(isSuspended: Bool) -> Bool {
        !isSuspended
    }

    /// SwiftUI may keep a stale field editor after a multiline TextField submits.
    /// A focused composer must first publish an explicit release edge.
    static func shouldReleaseBeforeSubmissionRestore(wasFocused: Bool) -> Bool {
        wasFocused
    }
}

enum ComposerEditorIdentity {
    static let viewIdentifier = "bubble.composer.editor"
}

enum OverlayKeyCode {
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let deleteBackward: UInt16 = 51
    static let escape: UInt16 = 53
    static let keypadEnter: UInt16 = 76
    static let deleteForward: UInt16 = 117
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126

    static let deletion: Set<UInt16> = [deleteBackward, deleteForward]
    static let composerReserved: Set<UInt16> = [
        returnKey, tab, escape, keypadEnter,
        leftArrow, rightArrow, downArrow, upArrow,
    ]
}

enum ComposerKeyRoutingPolicy {
    static func shouldRoute(
        hasText: Bool,
        keyCode: UInt16,
        commandModified: Bool,
        controlModified: Bool
    ) -> Bool {
        guard !commandModified, !controlModified else { return false }
        if OverlayKeyCode.deletion.contains(keyCode) { return true }
        return hasText && !OverlayKeyCode.composerReserved.contains(keyCode)
    }
}

enum ComposerReturnKeyAction: Equatable {
    case passThrough
    case insertNewline
    case toggleMount
    case submit
}

enum ComposerReturnKeyPolicy {
    static func action(
        keyCode: UInt16,
        hasMarkedText: Bool,
        shiftModified: Bool,
        optionModified: Bool,
        commandModified: Bool,
        controlModified: Bool,
        mountPaletteVisible: Bool
    ) -> ComposerReturnKeyAction {
        guard keyCode == OverlayKeyCode.returnKey || keyCode == OverlayKeyCode.keypadEnter else {
            return .passThrough
        }
        guard !hasMarkedText, !commandModified, !controlModified else {
            return .passThrough
        }
        if shiftModified || optionModified {
            return .insertNewline
        }
        return mountPaletteVisible ? .toggleMount : .submit
    }
}

enum OverlayEscapeAction: Equatable {
    case dismissSlashMenu
    case dismissAvatarPicker
    case dismissLoopList
    case dismissLoopClosePrompt
    case dismissRecordClosePrompt
    case cancelTurn
    case hideOverlay
}

enum OverlayEscapePolicy {
    static func action(
        slashMenuVisible: Bool,
        avatarPickerVisible: Bool,
        isBusy: Bool,
        loopListVisible: Bool = false,
        loopClosePromptVisible: Bool = false,
        recordClosePromptVisible: Bool = false
    ) -> OverlayEscapeAction {
        if slashMenuVisible { return .dismissSlashMenu }
        if avatarPickerVisible { return .dismissAvatarPicker }
        if loopListVisible { return .dismissLoopList }
        if loopClosePromptVisible { return .dismissLoopClosePrompt }
        if recordClosePromptVisible { return .dismissRecordClosePrompt }
        if isBusy { return .cancelTurn }
        return .hideOverlay
    }

    static func keepsOverlayVisible(after action: OverlayEscapeAction) -> Bool {
        action != .hideOverlay
    }

    static func requestsComposerFocus(after action: OverlayEscapeAction) -> Bool {
        action == .cancelTurn
    }
}

enum OverlayRenderPolicy {
    /// AppKit's display-link animator owns side-stage geometry. Animating the
    /// SwiftUI HStack as well interpolates the transcript width at subpixels,
    /// which makes text look softer while the panel opens.
    static let shouldAnimateSideStageContentLayout = false
    static let shouldRefreshHostingSurfaceAfterFrameSettle = true
    /// Pin the conversation to the current panel's leading edge while AppKit
    /// animates width, so target layout cannot clip the left side of the card.
    static let pinsConversationToLeadingEdge = true

    /// AppKit frame updates are for chrome size, not streaming text.
    static func layoutNeedsApply(previous: OverlayLayout?, next: OverlayLayout) -> Bool {
        previous != next
    }

    static func maskNeedsApply(previous: OverlayLayout?, next: OverlayLayout) -> Bool {
        previous != next
    }

    static func acceptsSessionLayout(
        layoutSessionID: UUID?,
        selectedSessionID: UUID
    ) -> Bool {
        layoutSessionID == selectedSessionID
    }

    static func reduceLayoutPreference(
        current: OverlayLayout,
        next: OverlayLayout
    ) -> OverlayLayout {
        guard next.sessionID != nil, next.totalHeight > 1 else {
            return current
        }
        return next
    }

    /// Token flushes must not hit disk; the turn-end persist is the durable write.
    static func shouldPersistStreamChunk(isBusy: Bool, childBusy: Bool) -> Bool {
        !isBusy && !childBusy
    }

    /// Hide/show animation owns the display link. Streaming must not rebuild SwiftUI
    /// while the panel is moving or ordered out.
    static func shouldFlushStreamToUI(overlayVisible: Bool, isHiding: Bool) -> Bool {
        overlayVisible && !isHiding
    }

    /// Parsing a growing structured response is proportional to the rendered
    /// prefix. Keep small replies at display rate, but give very large code,
    /// tables, and diagrams a bounded UI update cadence.
    static func streamFlushInterval(renderedBytes: Int) -> TimeInterval {
        switch renderedBytes {
        case ..<64_000: 1.0 / 120.0
        case ..<256_000: 1.0 / 60.0
        case ..<768_000: 1.0 / 30.0
        default: 1.0 / 20.0
        }
    }

    static func shouldResumeStream(panelVisible: Bool, isMoving: Bool) -> Bool {
        panelVisible && !isMoving
    }

    static func shouldAnimateSideStageResize(
        previousPreviewWidth: CGFloat,
        nextPreviewWidth: CGFloat
    ) -> Bool {
        abs(previousPreviewWidth - nextPreviewWidth) >= 1
    }

    /// Side-stage width and the first transcript reveal own the display-link
    /// animator. Composer chrome (quotes, attachments) must not, or SwiftUI
    /// relayouts the whole transcript on every spring tick.
    static func shouldAnimatePanelFrame(previous: OverlayLayout?, next: OverlayLayout) -> Bool {
        guard let previous else { return false }
        if shouldAnimateSideStageResize(
            previousPreviewWidth: previous.previewWidth,
            nextPreviewWidth: next.previewWidth
        ) {
            return true
        }
        return (previous.transcriptHeight > 1) != (next.transcriptHeight > 1)
    }

    /// Batch ordinary chrome layout on the next display pulse. Side-stage width
    /// changes must apply in the click's turn so the panel starts moving immediately.
    static func shouldDeferLayoutPulse(
        previousPreviewWidth: CGFloat,
        nextPreviewWidth: CGFloat
    ) -> Bool {
        abs(previousPreviewWidth - nextPreviewWidth) < 1
    }
}

enum ThoughtDisplayPolicy {
    static let liveTailCharacters = 2_000
    static let completedChunkCharacters = 2_000

    static func isTailTruncated(_ text: String) -> Bool {
        text.count > liveTailCharacters
    }

    static func chunks(_ text: String, streaming: Bool) -> [String] {
        if streaming {
            return [String(text.suffix(liveTailCharacters))]
        }
        guard text.count > completedChunkCharacters else { return [text] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: completedChunkCharacters, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }
}
