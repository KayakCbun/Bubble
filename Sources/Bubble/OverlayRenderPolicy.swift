import Foundation

enum OverlayRenderPolicy {
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
        true
    }
}
