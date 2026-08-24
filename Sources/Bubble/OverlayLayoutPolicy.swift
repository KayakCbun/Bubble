import CoreGraphics
import Foundation

enum OverlayHitTestPolicy {
    static func shouldHide(
        panelContainsClick: Bool,
        visibleCardContainsClick: Bool
    ) -> Bool {
        !panelContainsClick || !visibleCardContainsClick
    }
}

struct OverlayCardHitRegion {
    var rect: CGRect
    var cornerRadius: CGFloat

    func contains(_ point: CGPoint) -> Bool {
        guard rect.contains(point) else { return false }
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        if radius <= 0 { return true }
        if rect.insetBy(dx: radius, dy: 0).contains(point) { return true }
        if rect.insetBy(dx: 0, dy: radius).contains(point) { return true }
        let center = CGPoint(
            x: point.x < rect.midX ? rect.minX + radius : rect.maxX - radius,
            y: point.y < rect.midY ? rect.minY + radius : rect.maxY - radius
        )
        let dx = point.x - center.x
        let dy = point.y - center.y
        return dx * dx + dy * dy <= radius * radius
    }
}

struct OverlayLayout: Equatable {
    var totalHeight: CGFloat
    var transcriptHeight: CGFloat
    var pickerHeight: CGFloat
    var commandPaletteHeight: CGFloat
    var transcriptWidth: CGFloat
    var composerHeight: CGFloat
    var previewWidth: CGFloat = 0
}

enum OverlayLayoutPolicy {
    static func isTranscriptPresented(itemCount: Int, isStartingSession: Bool) -> Bool {
        itemCount > 0 || isStartingSession
    }

    static func transcriptHeight(isPresented: Bool, maximum: CGFloat) -> CGFloat {
        isPresented ? maximum : 0
    }

    /// Extra width the markdown pane adds to the right of the conversation card.
    static func previewExtraWidth(_ previewWidth: CGFloat, gap: CGFloat) -> CGFloat {
        previewWidth > 1 ? previewWidth + gap : 0
    }

    static func contentWidth(chatWidth: CGFloat, previewWidth: CGFloat, gap: CGFloat) -> CGFloat {
        chatWidth + previewExtraWidth(previewWidth, gap: gap)
    }

    static func fittedChatWidth(
        desired: CGFloat,
        sideStageWidth: CGFloat,
        visibleWidth: CGFloat,
        gap: CGFloat,
        bleed: CGFloat,
        minimum: CGFloat
    ) -> CGFloat {
        guard sideStageWidth > 1 else { return desired }
        let available = visibleWidth - sideStageWidth - gap - bleed * 2
        return min(desired, max(minimum, available.rounded(.down)))
    }

    /// Left edge of the panel so the visual center (composer) stays put while preview opens.
    static func panelOriginX(centerX: CGFloat, contentWidth: CGFloat, bleed: CGFloat) -> CGFloat {
        centerX - (contentWidth + bleed * 2) / 2
    }

    static func constrainedFrame(
        _ frame: CGRect,
        to visibleFrame: CGRect,
        constrainVertically: Bool = true
    ) -> CGRect {
        var result = frame
        let visibleWidth = min(result.width, visibleFrame.width)
        result.origin.x = min(max(result.origin.x, visibleFrame.minX), visibleFrame.maxX - visibleWidth)
        if constrainVertically {
            let visibleHeight = min(result.height, visibleFrame.height)
            result.origin.y = min(max(result.origin.y, visibleFrame.minY), visibleFrame.maxY - visibleHeight)
        }
        return result
    }
}

enum OverlayPixel {
    static func align(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let step = max(scale, 1)
        return (value * step).rounded() / step
    }

    static func align(_ rect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: align(rect.origin.x, scale: scale),
            y: align(rect.origin.y, scale: scale),
            width: align(rect.size.width, scale: scale),
            height: align(rect.size.height, scale: scale)
        )
    }
}

enum OverlaySpring {
    static let panelResponse: CGFloat = 0.32
    static let panelDamping: CGFloat = 0.94
    static let snappyResponse: CGFloat = 0.26
    static let snappyDamping: CGFloat = 0.90
    static let quickResponse: CGFloat = 0.18
    static let quickDamping: CGFloat = 0.94

    static func step(
        value: inout CGFloat,
        velocity: inout CGFloat,
        target: CGFloat,
        dt: CGFloat,
        response: CGFloat = panelResponse,
        damping: CGFloat = panelDamping
    ) {
        let omega = 2 * CGFloat.pi / max(response, 0.001)
        let accel = -omega * omega * (value - target) - 2 * damping * omega * velocity
        velocity += accel * dt
        value += velocity * dt
    }

    static func settled(
        value: CGFloat,
        velocity: CGFloat,
        target: CGFloat,
        distance: CGFloat = 0.35,
        speed: CGFloat = 10
    ) -> Bool {
        abs(value - target) < distance && abs(velocity) < speed
    }
}
