import Foundation

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

    /// Token flushes must not hit disk; the turn-end persist is the durable write.
    static func shouldPersistStreamChunk(isBusy: Bool, childBusy: Bool) -> Bool {
        !isBusy && !childBusy
    }

    /// Hide/show animation owns the display link. Streaming must not rebuild SwiftUI
    /// while the panel is moving or ordered out.
    static func shouldFlushStreamToUI(overlayVisible: Bool, isHiding: Bool) -> Bool {
        overlayVisible && !isHiding
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
