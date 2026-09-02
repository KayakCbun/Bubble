import CoreGraphics
import Foundation

enum OverlayHitTestPolicy {
    static func shouldHide(
        panelContainsClick: Bool,
        visibleCardContainsClick: Bool
    ) -> Bool {
        !panelContainsClick || !visibleCardContainsClick
    }

    static func shouldHideLocalPanelClick(
        atWindowPoint point: CGPoint,
        visibleCardRegions: [OverlayCardHitRegion]
    ) -> Bool {
        shouldHide(
            panelContainsClick: true,
            visibleCardContainsClick: visibleCardRegions.contains { $0.contains(point) }
        )
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
    var sessionID: UUID? = nil
    var totalHeight: CGFloat
    var transcriptHeight: CGFloat
    var pickerHeight: CGFloat
    var commandPaletteHeight: CGFloat
    var transcriptWidth: CGFloat
    var composerHeight: CGFloat
    var previewWidth: CGFloat = 0
    var chromeVisible: Bool = false
    var sessionTabCount: Int = 0
}

enum OverlayPalettePolicy {
    static let rowHeight: CGFloat = 52
    static let rowSpacing: CGFloat = 2
    static let commandVisibleLimit = 7
    static let mountVisibleLimit = 9
    static let captionChrome: CGFloat = 24
    static let searchChrome: CGFloat = 40
    static let padding: CGFloat = 16

    static func visibleRowCount(items: Int, isMount: Bool) -> Int {
        let limit = isMount ? mountVisibleLimit : commandVisibleLimit
        return min(max(items, 0), limit)
    }

    static func needsScroll(items: Int, isMount: Bool) -> Bool {
        items > (isMount ? mountVisibleLimit : commandVisibleLimit)
    }

    static func listHeight(items: Int, isMount: Bool) -> CGFloat {
        let rows = visibleRowCount(items: items, isMount: isMount)
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowSpacing
    }

    static func chromeHeight(items: Int, isMount: Bool, hasSearch: Bool) -> CGFloat {
        guard items > 0 else { return 0 }
        return listHeight(items: items, isMount: isMount)
            + captionChrome
            + (hasSearch ? searchChrome : 0)
            + padding
    }
}

enum OverlayLayoutPolicy {
    static func preferredTranscriptHeight(visibleHeight: CGFloat) -> CGFloat {
        max(620, (visibleHeight * 0.76).rounded())
    }

    static func isTranscriptPresented(
        itemCount: Int,
        isStartingSession: Bool,
        sessionTabCount: Int = 0
    ) -> Bool {
        itemCount > 0 || isStartingSession || sessionTabCount > 0
    }

    static func transcriptHeight(isPresented: Bool, maximum: CGFloat) -> CGFloat {
        isPresented ? maximum : 0
    }

    /// Quote and attachment chrome grow the composer into the transcript so the
    /// NSPanel stays put. Springing the whole overlay relayouts every message.
    static func fittedTranscriptHeight(
        base: CGFloat,
        composerHeight: CGFloat,
        restingComposerHeight: CGFloat,
        minimum: CGFloat = 160
    ) -> CGFloat {
        guard base > 1 else { return 0 }
        let extra = max(0, composerHeight - restingComposerHeight)
        return max(minimum, base - extra)
    }

    /// Extra width the markdown pane adds to the right of the conversation card.
    static func previewExtraWidth(_ previewWidth: CGFloat, gap: CGFloat) -> CGFloat {
        previewWidth > 1 ? previewWidth + gap : 0
    }

    /// Extra card origin relative to the conversation. The extra pane is painted
    /// beside the conversation and must not participate in the conversation's
    /// layout width, or SwiftUI will shift the card left of the current panel.
    static func extraPaneOriginX(conversationWidth: CGFloat, gap: CGFloat) -> CGFloat {
        conversationWidth + gap
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

    /// Composer X in the current panel, so the input stays centered while the
    /// conversation slides left into reserved side-stage width.
    static func composerOriginX(
        panelWidth: CGFloat,
        composerWidth: CGFloat,
        bleed: CGFloat
    ) -> CGFloat {
        bleed + (panelWidth - bleed * 2 - composerWidth) / 2
    }

    /// Centering a target-width card stack in a still-animating smaller panel
    /// chops the conversation's leading edge. Pinning to leading does not.
    static func conversationLeadingClip(
        currentContentWidth: CGFloat,
        stackWidth: CGFloat,
        pinToLeading: Bool
    ) -> CGFloat {
        if pinToLeading { return 0 }
        return max(0, (stackWidth - currentContentWidth) / 2)
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

enum RunningSweepPolicy {
    static let cycleDuration: TimeInterval = 1.45
    static let minimumFrameInterval: TimeInterval = 1.0 / 120.0
    static let highlightRadius = 0.24
    static let offscreenPadding = 0.12

    static func progress(at time: TimeInterval) -> Double {
        let cycle = max(cycleDuration, .leastNonzeroMagnitude)
        let remainder = time.truncatingRemainder(dividingBy: cycle)
        return (remainder < 0 ? remainder + cycle : remainder) / cycle
    }

    static func highlightCenter(at time: TimeInterval) -> Double {
        let start = -(highlightRadius + offscreenPadding)
        let end = 1 + highlightRadius + offscreenPadding
        return start + (end - start) * progress(at: time)
    }

    /// Horizontal axial gradient start, in unit space across the word.
    static func startPointX(at progress: Double) -> Double {
        progress - highlightRadius
    }

    /// Horizontal axial gradient end, in unit space across the word.
    static func endPointX(at progress: Double) -> Double {
        progress + highlightRadius
    }
}

enum RunningSweepPresentationPolicy {
    /// Show a transcript-level running label as soon as the turn starts,
    /// before the first assistant token creates a live bubble to host it.
    static func showsPendingLabel(isBusy: Bool, streamingAssistantID: UUID?) -> Bool {
        isBusy && streamingAssistantID == nil
    }
}

enum TranscriptChunkBoundaryPolicy {
    static let minimumTopInset: CGFloat = 6

    static func topInset(isContinuation: Bool) -> CGFloat {
        isContinuation ? 8 : 0
    }
}

enum RecordCardLayoutPolicy {
    static let liveLineLimit = 4
    static let flushedBodyMaxHeight: CGFloat = 180
    static let chromeHeight: CGFloat = 36
    static let lineHeight: CGFloat = 18
    static let padding: CGFloat = 24
    static let scrollerWidth: CGFloat = 10
    static let scrollerKnobWidth: CGFloat = 7
    static let scrollerTrailingInset: CGFloat = 3

    static func scrollerKnobHeight(contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0, contentHeight > viewportHeight + 0.5 else { return 0 }
        let proportional = viewportHeight * (viewportHeight / contentHeight)
        return min(viewportHeight, max(scrollerKnobWidth, proportional))
    }

    static func scrollerKnobOffset(
        contentOffset: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        knobHeight: CGFloat
    ) -> CGFloat {
        let travel = max(contentHeight - viewportHeight, 1)
        let track = max(viewportHeight - knobHeight, 0)
        let progress = min(1, max(0, contentOffset / travel))
        return progress * track
    }

    static func scrollerKnobFrame(in suggested: CGRect) -> CGRect {
        CGRect(
            x: suggested.midX - scrollerKnobWidth / 2,
            y: suggested.minY,
            width: scrollerKnobWidth,
            height: max(scrollerKnobWidth, suggested.height)
        )
    }

    /// A stadium: semicircle caps and a rectangular body. `NSBezierPath`
    /// rounded-rect corners shrink at this size, so the knob is built from arcs.
    static func scrollerKnobCapsulePath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        guard rect.width > 0, rect.height > 0 else { return path }
        let radius = min(rect.width, rect.height) / 2
        if rect.height <= rect.width + 0.5 {
            path.addEllipse(in: rect)
            return path
        }
        let midX = rect.midX
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(
            center: CGPoint(x: midX, y: rect.minY + radius),
            radius: radius,
            startAngle: .pi,
            endAngle: 2 * .pi,
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(
            center: CGPoint(x: midX, y: rect.maxY - radius),
            radius: radius,
            startAngle: 0,
            endAngle: .pi,
            clockwise: false
        )
        path.closeSubpath()
        return path
    }

    static func height(text: String, live: Bool) -> CGFloat {
        let lines = max(1, text.split(whereSeparator: \.isNewline).count)
        if live {
            return chromeHeight + CGFloat(min(lines, liveLineLimit)) * lineHeight + padding
        }
        let body = min(CGFloat(lines) * lineHeight, flushedBodyMaxHeight)
        return chromeHeight + body + padding
    }
}

enum TranscriptEstimatedHeightPolicy {
    static func height(for text: String) -> CGFloat {
        let lineCount = max(1, text.split(whereSeparator: \.isNewline).count)
        let roughLines = min(18, max(lineCount, Int(ceil(Double(text.count) / 92.0))))
        return max(42, min(420, CGFloat(roughLines) * 19 + 26))
    }
}

enum OverlaySpring {
    static let panelResponse: CGFloat = 0.22
    static let panelDamping: CGFloat = 0.86
    static let snappyResponse: CGFloat = 0.18
    static let snappyDamping: CGFloat = 0.82
    static let quickResponse: CGFloat = 0.14
    static let quickDamping: CGFloat = 0.88
    static let fadeResponse: CGFloat = 0.16
    static let fadeDamping: CGFloat = 0.92

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
