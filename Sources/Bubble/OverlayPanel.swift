import AppKit

final class OverlayRootView: NSView {
    var hitRegions: [OverlayCardHitRegion] = []
    private var widthToggleVisible = false
    private var onWidthToggle: (() -> Void)?
    private var onPinToggle: (() -> Void)?
    private var onPreviewFinder: (() -> Void)?
    private var onPreviewClose: (() -> Void)?
    private var onPreviewBack: (() -> Void)?
    private var maskTranscriptHeight: CGFloat = 0
    private var maskPickerHeight: CGFloat = 0
    private var maskCommandPaletteHeight: CGFloat = 0
    private var maskTranscriptWidth = OverlayMetrics.transcriptWidthDefault
    private var maskComposerHeight = OverlayMetrics.minHeight
    private var maskPreviewWidth: CGFloat = 0
    private var maskPreviewIsMarkdown = false
    private var maskPreviewHasBack = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func installWidthToggle(onToggle: @escaping () -> Void) {
        onWidthToggle = onToggle
    }

    func installPinToggle(onToggle: @escaping () -> Void) {
        onPinToggle = onToggle
    }

    func installPreviewControls(
        onFinder: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onBack: @escaping () -> Void
    ) {
        onPreviewFinder = onFinder
        onPreviewClose = onClose
        onPreviewBack = onBack
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isOpaque = false
        window?.backgroundColor = .clear
        window?.hasShadow = false
        window?.invalidateShadow()
        syncLayerForText()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncLayerForText()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
    }

    override func layout() {
        super.layout()
        rebuildCardMask()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if control(at: point) != nil {
            return self
        }
        if hitRegions.contains(where: { $0.contains(point) }) {
            return super.hitTest(point)
        }
        return nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func containsVisibleCard(atScreenPoint screenPoint: NSPoint) -> Bool {
        guard let window else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)
        return control(at: localPoint) != nil
            || hitRegions.contains(where: { $0.contains(localPoint) })
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch control(at: point) {
        case .pin:
            onPinToggle?()
            return
        case .width:
            onWidthToggle?()
            return
        case .previewFinder:
            onPreviewFinder?()
            return
        case .previewClose:
            onPreviewClose?()
            return
        case .previewBack:
            onPreviewBack?()
            return
        case nil:
            break
        }
        super.mouseDown(with: event)
    }

    private enum TranscriptControl {
        case pin
        case width
        case previewFinder
        case previewClose
        case previewBack
    }

    private func control(at point: NSPoint) -> TranscriptControl? {
        guard widthToggleVisible else { return nil }

        // The transparent root view is flipped while the hosted SwiftUI content
        // can report the visual top edge at either vertical edge. Keep matching
        // zones on both edges, but split the two controls horizontally so a
        // physical click can never dispatch both actions.
        let hitWidth: CGFloat = 36
        let hitHeight = OverlayMetrics.shadowInset + 36
        let atEitherVerticalEdge = point.y <= hitHeight || point.y >= bounds.maxY - hitHeight
        guard atEitherVerticalEdge else { return nil }

        if maskPreviewWidth > 1 {
            let previewLeading = OverlayMetrics.shadowInset
                + maskTranscriptWidth
                + OverlayMetrics.stackSpacing
            let previewTrailing = previewLeading + maskPreviewWidth
            let closeRect = NSRect(
                x: previewTrailing - hitWidth,
                y: 0,
                width: hitWidth,
                height: bounds.height
            )
            if closeRect.contains(point) {
                return .previewClose
            }
            if maskPreviewIsMarkdown {
                let finderRect = NSRect(
                    x: previewTrailing - hitWidth * 2,
                    y: 0,
                    width: hitWidth,
                    height: bounds.height
                )
                if finderRect.contains(point) {
                    return .previewFinder
                }
                if maskPreviewHasBack {
                    let backRect = NSRect(
                        x: previewLeading,
                        y: 0,
                        width: hitWidth,
                        height: bounds.height
                    )
                    if backRect.contains(point) {
                        return .previewBack
                    }
                }
            }
        }

        let trailingEdge = OverlayMetrics.shadowInset + maskTranscriptWidth
        let widthRect = NSRect(
            x: trailingEdge - hitWidth,
            y: 0,
            width: hitWidth,
            height: bounds.height
        )
        if widthRect.contains(point) {
            return .width
        }

        let pinRect = NSRect(
            x: trailingEdge - hitWidth * 2,
            y: 0,
            width: hitWidth,
            height: bounds.height
        )
        return pinRect.contains(point) ? .pin : nil
    }

    func applyCardMask(
        transcriptHeight: CGFloat,
        pickerHeight: CGFloat = 0,
        commandPaletteHeight: CGFloat = 0,
        transcriptWidth: CGFloat = OverlayMetrics.transcriptWidthDefault,
        composerHeight: CGFloat = OverlayMetrics.minHeight,
        previewWidth: CGFloat = 0,
        previewIsMarkdown: Bool = false,
        previewHasBack: Bool = false
    ) {
        maskTranscriptHeight = transcriptHeight
        maskPickerHeight = pickerHeight
        maskCommandPaletteHeight = commandPaletteHeight
        maskTranscriptWidth = transcriptWidth
        maskComposerHeight = composerHeight > 1 ? composerHeight : OverlayMetrics.minHeight
        maskPreviewWidth = previewWidth
        maskPreviewIsMarkdown = previewIsMarkdown
        maskPreviewHasBack = previewHasBack
        rebuildCardMask()
    }

    private func rebuildCardMask() {
        let transcriptHeight = maskTranscriptHeight
        let pickerHeight = maskPickerHeight
        let commandPaletteHeight = maskCommandPaletteHeight
        let chatW = maskTranscriptWidth > 1 ? maskTranscriptWidth : OverlayMetrics.transcriptWidthDefault
        let inputW = OverlayMetrics.inputWidth
        let inputH = maskComposerHeight > 1 ? maskComposerHeight : OverlayMetrics.minHeight
        let gap = OverlayMetrics.stackSpacing
        widthToggleVisible = transcriptHeight > 1
        var hit: [OverlayCardHitRegion] = []
        func addRect(_ rect: CGRect, cornerRadius: CGFloat) {
            hit.append(OverlayCardHitRegion(rect: rect, cornerRadius: cornerRadius))
        }

        let inset = OverlayMetrics.shadowInset
        let previewExtra = OverlayLayoutPolicy.previewExtraWidth(maskPreviewWidth, gap: gap)
        let fallbackWidth = (transcriptHeight > 1 ? chatW + previewExtra : inputW) + inset * 2
        let panelWidth = bounds.width > 1 ? bounds.width : fallbackWidth
        let inputX = OverlayPixel.align(
            OverlayLayoutPolicy.composerOriginX(
                panelWidth: panelWidth,
                composerWidth: inputW,
                bleed: inset
            ),
            scale: backingScale
        )
        let inputY = max(inset, bounds.height - inset - inputH)
        if transcriptHeight > 1 {
            let chatY = max(inset, inputY - gap - transcriptHeight)
            addRect(
                CGRect(x: inset, y: chatY, width: chatW, height: transcriptHeight),
                cornerRadius: OverlayMetrics.transcriptCornerRadius
            )
            if maskPreviewWidth > 1 {
                addRect(
                    CGRect(
                        x: inset + chatW + gap,
                        y: chatY,
                        width: maskPreviewWidth,
                        height: transcriptHeight
                    ),
                    cornerRadius: OverlayMetrics.transcriptCornerRadius
                )
            }
        }
        if pickerHeight > 1 {
            let pickerY = max(inset, inputY - gap - pickerHeight)
            addRect(
                CGRect(
                    x: inputX + OverlayMetrics.pickerLeading,
                    y: pickerY,
                    width: OverlayMetrics.pickerWidth,
                    height: pickerHeight
                ),
                cornerRadius: OverlayMetrics.cornerRadius
            )
        }
        if commandPaletteHeight > 1 {
            addRect(
                CGRect(
                    x: inputX,
                    y: max(inset, inputY - gap - commandPaletteHeight),
                    width: inputW,
                    height: commandPaletteHeight
                ),
                cornerRadius: OverlayMetrics.transcriptCornerRadius
            )
        }
        addRect(
            CGRect(x: inputX, y: inputY, width: inputW, height: inputH),
            cornerRadius: OverlayMetrics.cornerRadius
        )
        hitRegions = hit
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func syncLayerForText() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.masksToBounds = false
        layer?.mask = nil
        layer?.shouldRasterize = false
        layer?.contentsScale = backingScale
        layer?.allowsEdgeAntialiasing = false
        for subview in subviews {
            subview.layer?.contentsScale = backingScale
            subview.layer?.shouldRasterize = false
            subview.layer?.masksToBounds = false
        }
    }

}

final class OverlayPanel: NSPanel {
    var pasteAction: (() -> Bool)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: OverlayMetrics.inputWidth, height: OverlayMetrics.minHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        animationBehavior = .none
        hidesOnDeactivate = false
        displaysWhenScreenProfileChanges = true
        isMovable = true
        // Avoid the system drawing a second rounded glass slab behind the cards.
        invalidateShadow()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard OverlayEditCommands.isCommandModified(event) else {
            return false
        }
        if OverlayEditCommands.handleCommandEditKey(event, paste: pasteAction) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
