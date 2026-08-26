import AppKit
import SwiftUI

final class OverlayController: NSObject, NSWindowDelegate {
    let sessions = SessionTabsStore()
    var store: ChatStore { sessions.activeStore }

    private let panel = OverlayPanel()
    private let rootView = OverlayRootView(frame: .zero)
    private weak var hostingView: NSView?
    private let tapMonitor = CommandTapMonitor()
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeys: Any?
    private var connectingRuntimeIDs: Set<UUID> = []
    private var restoredPosition = false
    private var isUpdatingFrame = false
    private var isHiding = false
    private var hideGeneration = 0
    private var targetPanelFrame: NSRect?
    private var restCenterX: CGFloat?
    private var restBottomY: CGFloat?
    private var widthToggleGeneration = 0
    private var pendingTranscriptWide: Bool?
    private var pendingLayout: OverlayLayout?
    private var layoutQueued = false
    private var lastAppliedLayout: OverlayLayout?
    private var pendingSessionPresentationID: UUID?
    private let frameAnimator = OverlayFrameAnimator()
    private var commandReturnApplication: NSRunningApplication?
    private var workspaceRevealGeneration = 0
    private var workspaceRevealPending = false
    private var chromeRevealGeneration = 0
    private var chromeRevealPending = false
    private var chromeHideGeneration = 0

    private let positionCenterXKey = "bubble.position.centerX"
    private let positionBottomYKey = "bubble.position.bottomY"

    func start() {
        OverlayPaths.bootstrap()
        installView()
        tapMonitor.onDoubleTap = { [weak self] in
            self?.toggleFromCommandTap()
        }
        tapMonitor.start()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.hideIfClickOutside()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.type == .leftMouseDown,
               let index = self.rootView.sessionTabIndex(atWindowPoint: event.locationInWindow),
               self.sessions.tabs.indices.contains(index) {
                self.sessions.select(self.sessions.tabs[index].id)
                return nil
            }
            let visible = self.rootView.containsVisibleCard(atScreenPoint: NSEvent.mouseLocation)
            if OverlayHitTestPolicy.shouldHide(
                panelContainsClick: true,
                visibleCardContainsClick: visible
            ) {
                self.hide()
                return nil
            }
            return event
        }
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.handleEscape()
                return nil
            }
            if OverlayEditCommands.isCommandModified(event),
               OverlayEditCommands.handleCommandEditKey(event, paste: self?.panel.pasteAction) {
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                if let textView = self?.panel.firstResponder as? NSTextView, textView.hasMarkedText() {
                    return event
                }
                if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                    self?.insertComposerNewline()
                    return nil
                }
            }
            if self?.store.slashMenuVisible == true {
                switch event.keyCode {
                case 126:
                    self?.store.moveSlashHighlight(-1)
                    return nil
                case 125:
                    self?.store.moveSlashHighlight(1)
                    return nil
                case 123:
                    if self?.store.isMountPalette == true {
                        self?.store.leaveMountFolder()
                        return nil
                    }
                case 124:
                    if self?.store.isMountPalette == true {
                        self?.store.completeHighlightedSlash()
                        return nil
                    }
                case 36, 76:
                    if self?.store.isMountPalette == true {
                        if let textView = self?.panel.firstResponder as? NSTextView, textView.hasMarkedText() {
                            return event
                        }
                        self?.store.toggleHighlightedMount()
                        return nil
                    }
                case 48:
                    self?.store.completeHighlightedSlash()
                    return nil
                default:
                    break
                }
            }
            return event
        }
        connectAllIfNeeded()
    }

    func stop() {
        tapMonitor.stop()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let localKeys { NSEvent.removeMonitor(localKeys) }
        sessions.prepareToQuit()
        frameAnimator.cancel()
        hide(animated: false)
    }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    private func toggleFromCommandTap() {
        if panel.isVisible {
            let application = commandReturnApplication
            commandReturnApplication = nil
            hide(animated: true, returningFocusTo: application)
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let bubblePID = ProcessInfo.processInfo.processIdentifier
        let origin = CommandFocusReturnPolicy.remembers(
            frontmostPID: frontmost?.processIdentifier,
            bubblePID: bubblePID
        ) ? frontmost : nil
        show(returningFocusTo: origin)
    }

    func show() {
        show(returningFocusTo: nil)
    }

    private func show(returningFocusTo application: NSRunningApplication?) {
        if !CommandFocusReturnPolicy.preservesExistingTarget(
            panelVisible: panel.isVisible,
            requestedTargetPresent: application != nil
        ) {
            commandReturnApplication = application
        }
        restorePositionIfNeeded()
        syncVisibleScreenWidth()
        hideGeneration += 1
        isHiding = false
        panel.ignoresMouseEvents = false
        let appearing = !panel.isVisible
        rememberRestPosition(panel.frame)
        if appearing {
            var start = panel.frame
            start.origin.y -= 16
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.alphaValue = 0
            panel.setFrame(start, display: false)
            CATransaction.commit()
            targetPanelFrame = NSRect(
                x: (restCenterX ?? panel.frame.midX) - panel.frame.width / 2,
                y: restBottomY ?? (panel.frame.minY + 10),
                width: panel.frame.width,
                height: panel.frame.height
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        position()
        if appearing || panel.alphaValue < 0.99 {
            let dest = targetPanelFrame ?? panel.frame
            isUpdatingFrame = true
            store.setStreamUISuspended(true)
            if appearing {
                frameAnimator.syncFromPanel()
            }
            frameAnimator.onSettled = { [weak self] in
                self?.finishFrameAnimation()
            }
            frameAnimator.retarget(frame: dest, alpha: 1)
        } else {
            store.setStreamUISuspended(false)
        }
        store.requestFocus()
        OverlayPulse.shared.onNextFrame { [weak self] in
            self?.store.refreshCatalog()
        }
        Task { @MainActor in
            await connectIfNeeded()
        }
    }

    func hide(animated: Bool = true) {
        hide(animated: animated, returningFocusTo: nil)
    }

    private func hide(animated: Bool, returningFocusTo application: NSRunningApplication?) {
        commandReturnApplication = nil
        store.cancelPendingResumeAction()
        store.setStreamUISuspended(true)
        ImageZoomController.shared.close()
        MermaidZoomController.shared.close()
        guard panel.isVisible else {
            panel.orderOut(nil)
            application?.activate(options: [])
            return
        }
        guard animated else {
            isHiding = false
            frameAnimator.cancel()
            panel.alphaValue = 1
            panel.orderOut(nil)
            application?.activate(options: [])
            return
        }
        if isHiding { return }
        isHiding = true
        hideGeneration += 1
        let generation = hideGeneration
        isUpdatingFrame = true
        panel.ignoresMouseEvents = true
        var dest = panel.frame
        dest.origin.y -= 14
        frameAnimator.syncFromPanel()
        frameAnimator.onSettled = { [weak self] in
            guard let self, self.hideGeneration == generation, self.isHiding else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.panel.ignoresMouseEvents = false
            if let restX = self.restCenterX, let restY = self.restBottomY {
                var rest = self.panel.frame
                rest.origin.x = restX - rest.width / 2
                rest.origin.y = restY
                self.panel.setFrame(rest, display: false)
            }
            self.isHiding = false
            self.finishFrameAnimation()
            application?.activate(options: [])
        }
        frameAnimator.retarget(frame: dest, alpha: 0)
    }

    var isTrustedForHotkey: Bool { tapMonitor.isTrusted }

    func promptAccessibility() {
        tapMonitor.promptForTrust()
        CommandTapMonitor.openAccessibilitySettings()
    }

    private func installView() {
        for runtime in sessions.allRuntimes {
            configureRuntime(runtime)
        }
        sessions.onRuntimeCreated = { [weak self] runtime in
            self?.configureRuntime(runtime)
        }
        sessions.onSelectionChanged = { [weak self] _, next in
            guard let self else { return }
            self.configureRuntime(next)
            next.visibleScreenWidth = self.currentVisibleFrame()?.width ?? next.visibleScreenWidth
            next.setStreamUISuspended(!self.panel.isVisible || self.isHiding)
            self.position(confirmsSessionPresentation: false)
        }
        let root = SessionOverlayView(
            sessions: sessions,
            onEscape: { [weak self] in self?.hide() },
            onToggleWidth: { [weak self] in self?.requestTranscriptWidthToggle() }
        )
        .onPreferenceChange(OverlayLayoutKey.self) { [weak self] layout in
            self?.scheduleApply(layout)
        }
        let hosting = NSHostingView(rootView: root)
        hostingView = hosting
        hosting.wantsLayer = true
        hosting.safeAreaRegions = []
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        hosting.layer?.masksToBounds = false
        hosting.layer?.shouldRasterize = false
        hosting.layer?.contentsScale = panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        hosting.autoresizingMask = [.width, .height]

        let initial = NSRect(x: 0, y: 0, width: OverlayMetrics.inputWidth, height: OverlayMetrics.minHeight)
        rootView.frame = initial
        hosting.frame = initial
        rootView.addSubview(hosting)
        rootView.installWidthToggle { [weak self] in
            self?.requestTranscriptWidthToggle()
        }
        rootView.installPinToggle { [weak self] in
            self?.store.toggleOverlayPin()
        }
        rootView.installPreviewControls(
            onFinder: { [weak self] in
                guard let path = self?.store.markdownPreview?.path else { return }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            },
            onClose: { [weak self] in
                self?.store.closeSideStage()
            },
            onBack: { [weak self] in
                self?.store.returnToWorkspaceStage()
            }
        )
        panel.contentView = rootView
        panel.delegate = self
        panel.pasteAction = { [weak self] in
            self?.pasteIntoDraft() ?? false
        }
        panel.setFrame(initial, display: false)
        frameAnimator.attach(panel)
        rootView.applyCardMask(transcriptHeight: 0, pickerHeight: 0, composerHeight: OverlayMetrics.minHeight)
    }

    private func configureRuntime(_ runtime: ChatStore) {
        runtime.onHideOverlay = { [weak self] in
            self?.hide()
        }
        runtime.onWorkspacePanePresentationRequested = { [weak self] in
            self?.requestWorkspacePaneReveal()
        }
        runtime.onSideStageChromePresentationRequested = { [weak self] in
            self?.requestSideStageChromeReveal()
            self?.position()
        }
        runtime.onSideStageChromeDismissalRequested = { [weak self] in
            self?.requestSideStageChromeHide()
        }
        runtime.onSideStageChromeInvalidated = { [weak self] in
            self?.invalidateSideStageChrome()
        }
    }

    private func scheduleApply(_ layout: OverlayLayout) {
        guard OverlayRenderPolicy.acceptsSessionLayout(
            layoutSessionID: layout.sessionID,
            selectedSessionID: store.runtimeID
        ) else {
            return
        }
        let confirmsSessionPresentation = sessions.isAwaitingSelectedLayout(layout.sessionID)
        guard confirmsSessionPresentation
                || OverlayRenderPolicy.layoutNeedsApply(previous: lastAppliedLayout, next: layout) else {
            return
        }
        let previousPreviewWidth = lastAppliedLayout?.previewWidth ?? 0
        if !OverlayRenderPolicy.shouldDeferLayoutPulse(
            previousPreviewWidth: previousPreviewWidth,
            nextPreviewWidth: layout.previewWidth
        ) {
            pendingLayout = nil
            apply(layout)
            return
        }
        if !OverlayRenderPolicy.shouldAnimateSideStageResize(
            previousPreviewWidth: previousPreviewWidth,
            nextPreviewWidth: layout.previewWidth
        ) {
            pendingLayout = nil
            apply(layout)
            return
        }
        pendingLayout = layout
        guard !layoutQueued else { return }
        layoutQueued = true
        OverlayPulse.shared.onNextFrame { [weak self] in
            guard let self else { return }
            self.layoutQueued = false
            if let pending = self.pendingLayout {
                self.pendingLayout = nil
                self.apply(pending)
            }
        }
    }

    private func apply(
        _ layout: OverlayLayout,
        confirmsSessionPresentation: Bool = true
    ) {
        guard !isHiding,
              layout.totalHeight > 1,
              OverlayRenderPolicy.acceptsSessionLayout(
                  layoutSessionID: layout.sessionID,
                  selectedSessionID: store.runtimeID
              ) else { return }
        let height = max(OverlayMetrics.minHeight, min(layout.totalHeight.rounded(), OverlayMetrics.maxHeight))
        let hasTranscript = layout.transcriptHeight > 1
            || !store.visibleItems.isEmpty
            || store.isStartingSession
            || store.sideStagePresented
        let chatWidth = hasTranscript
            ? layout.transcriptWidth
            : OverlayMetrics.inputWidth
        let previewExtra = OverlayLayoutPolicy.previewExtraWidth(
            layout.previewWidth,
            gap: OverlayMetrics.stackSpacing
        )
        let bleed = OverlayMetrics.shadowInset
        var frame = targetPanelFrame ?? panel.frame
        let previousHeight = frame.height
        let centerX = restCenterX ?? frame.midX
        let bottomY = restBottomY ?? frame.minY
        let contentWidth = chatWidth + previewExtra
        frame.size = NSSize(
            width: contentWidth + bleed * 2,
            height: height + bleed * 2
        )
        frame.origin.x = OverlayLayoutPolicy.panelOriginX(
            centerX: centerX,
            contentWidth: contentWidth,
            bleed: bleed
        )
        frame.origin.y = bottomY
        let heightChanged = abs(frame.height - previousHeight) > 0.5
        constrainToVisibleScreens(&frame, constrainVertically: heightChanged)
        let destChanged = targetPanelFrame.map {
            abs($0.height - frame.height) > 0.5
                || abs($0.width - frame.width) > 0.5
                || abs($0.origin.x - frame.origin.x) > 0.5
        } ?? (
            abs(frame.height - panel.frame.height) > 0.5
                || abs(panel.frame.width - frame.width) > 0.5
                || abs(panel.frame.origin.x - frame.origin.x) > 0.5
        )
        let applied = OverlayLayout(
            sessionID: layout.sessionID,
            totalHeight: height,
            transcriptHeight: layout.transcriptHeight,
            pickerHeight: layout.pickerHeight,
            commandPaletteHeight: layout.commandPaletteHeight,
            transcriptWidth: chatWidth,
            composerHeight: layout.composerHeight,
            previewWidth: layout.previewWidth,
            chromeVisible: layout.chromeVisible,
            sessionTabCount: layout.sessionTabCount
        )
        let animateFrame = panel.isVisible && OverlayRenderPolicy.shouldAnimatePanelFrame(
            previous: lastAppliedLayout,
            next: applied
        )
        let needsMask = OverlayRenderPolicy.maskNeedsApply(previous: lastAppliedLayout, next: applied)
        if destChanged, !animateFrame, needsMask {
            applyMask(layout: applied, width: chatWidth)
        }
        if destChanged {
            updatePanelFrame(frame, animated: animateFrame)
        }
        if needsMask, !destChanged || animateFrame {
            applyMask(layout: applied, width: chatWidth)
        }
        if confirmsSessionPresentation {
            lastAppliedLayout = applied
        }
        if confirmsSessionPresentation, let sessionID = applied.sessionID {
            if isUpdatingFrame || frameAnimator.isAnimating {
                pendingSessionPresentationID = sessionID
            } else {
                sessions.selectedLayoutDidApply(sessionID)
            }
        }
        if workspaceRevealPending, layout.previewWidth > 0, !destChanged {
            scheduleWorkspacePaneRevealOnNextFrame()
        }
    }

    private func position(confirmsSessionPresentation: Bool = true) {
        let contentHeight = max(
            OverlayMetrics.minHeight,
            panel.frame.height - OverlayMetrics.shadowInset * 2
        )
        let previewWidth = currentPreviewWidth
        let transcriptWidth = OverlayMetrics.fittedTranscriptWidth(
            wide: store.transcriptWide,
            sideStageWidth: previewWidth,
            visibleWidth: store.visibleScreenWidth
        )
        apply(OverlayLayout(
            sessionID: store.runtimeID,
            totalHeight: contentHeight,
            transcriptHeight: (store.visibleItems.isEmpty && !store.isStartingSession && !store.sideStagePresented && !sessions.showsTabs)
                ? 0
                : max(0, contentHeight - OverlayMetrics.minHeight - OverlayMetrics.stackSpacing),
            pickerHeight: store.showAvatarPicker ? OverlayMetrics.pickerHeight : 0,
            commandPaletteHeight: store.slashPaletteChromeHeight,
            transcriptWidth: transcriptWidth,
            composerHeight: store.composerChromeHeight,
            previewWidth: previewWidth,
            chromeVisible: store.sideStageChromeVisible,
            sessionTabCount: sessions.showsTabs ? sessions.tabs.count : 0
        ), confirmsSessionPresentation: confirmsSessionPresentation)
    }

    private func applyMask(layout: OverlayLayout, width: CGFloat) {
        rootView.applyCardMask(
            transcriptHeight: layout.transcriptHeight,
            pickerHeight: layout.pickerHeight,
            commandPaletteHeight: layout.commandPaletteHeight,
            transcriptWidth: layout.transcriptWidth,
            composerHeight: layout.composerHeight,
            previewWidth: SideStageChromePolicy.hitPreviewWidth(
                chromeVisible: store.sideStageChromeVisible,
                previewWidth: layout.previewWidth
            ),
            previewIsMarkdown: store.markdownPreview != nil,
            previewHasBack: store.canReturnToWorkspace,
            sessionTabCount: layout.sessionTabCount
        )
    }

    private func pinAboveDock(_ frame: inout NSRect) {
        guard let visible = currentVisibleFrame() else { return }
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.minY + OverlayMetrics.dockGap
        constrainToVisibleScreens(&frame)
    }

    private func restorePositionIfNeeded() {
        guard !restoredPosition else { return }
        restoredPosition = true

        var frame = panel.frame
        let defaults = UserDefaults.standard
        if defaults.object(forKey: positionCenterXKey) != nil,
           defaults.object(forKey: positionBottomYKey) != nil {
            frame.origin.x = defaults.double(forKey: positionCenterXKey) - frame.width / 2
            frame.origin.y = defaults.double(forKey: positionBottomYKey)
            constrainToVisibleScreens(&frame)
        } else {
            pinAboveDock(&frame)
        }
        panel.setFrame(frame, display: false)
        rememberRestPosition(frame)
    }

    private func constrainToVisibleScreens(
        _ frame: inout NSRect,
        constrainVertically: Bool = true
    ) {
        let targetScreen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) }
            ?? currentVisibleFrame().flatMap { visible in
                NSScreen.screens.first { $0.visibleFrame == visible }
            }
            ?? panel.screen
            ?? NSScreen.main
        let scale = targetScreen?.backingScaleFactor ?? 2
        guard let visible = targetScreen?.visibleFrame else {
            frame = OverlayPixel.align(frame, scale: scale)
            return
        }
        frame = OverlayLayoutPolicy.constrainedFrame(
            frame,
            to: visible,
            constrainVertically: constrainVertically
        )
        frame = OverlayPixel.align(frame, scale: scale)
    }

    private func updatePanelFrame(_ frame: NSRect, animated: Bool) {
        let frame = OverlayPixel.align(frame, scale: panel.screen?.backingScaleFactor ?? 2)
        isUpdatingFrame = true
        targetPanelFrame = frame

        guard animated, panel.isVisible else {
            frameAnimator.jump(to: frame, alpha: 1)
            finishFrameAnimation()
            return
        }

        store.setStreamUISuspended(true)

        frameAnimator.onSettled = { [weak self] in
            self?.finishFrameAnimation()
        }
        frameAnimator.retarget(frame: frame, alpha: 1)
    }

    private func finishFrameAnimation() {
        if let target = targetPanelFrame {
            let scale = panel.screen?.backingScaleFactor ?? 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.setFrame(OverlayPixel.align(target, scale: scale), display: false)
            CATransaction.commit()
        }
        targetPanelFrame = nil
        isUpdatingFrame = false
        if let sessionID = pendingSessionPresentationID {
            pendingSessionPresentationID = nil
            sessions.selectedLayoutDidApply(sessionID)
        }
        if workspaceRevealPending,
           OverlayRenderPolicy.shouldRefreshHostingSurfaceAfterFrameSettle {
            hostingView?.needsDisplay = true
        }
        scheduleWorkspacePaneRevealOnNextFrame()
        if !workspaceRevealPending,
           OverlayRenderPolicy.shouldResumeStream(
            panelVisible: panel.isVisible,
            isMoving: isHiding || frameAnimator.isAnimating
        ) {
            store.setStreamUISuspended(false)
        }
    }

    private func requestWorkspacePaneReveal() {
        workspaceRevealPending = true
        workspaceRevealGeneration += 1
        store.setStreamUISuspended(true)
        if (lastAppliedLayout?.previewWidth ?? 0) > 0,
           !isUpdatingFrame,
           !frameAnimator.isAnimating {
            scheduleWorkspacePaneRevealOnNextFrame()
        }
    }

    private func requestSideStageChromeReveal() {
        chromeHideGeneration += 1
        chromeRevealGeneration += 1
        let generation = chromeRevealGeneration
        chromeRevealPending = true
        OverlayPulse.shared.onNextFrame { [weak self] in
            guard let self,
                  generation == self.chromeRevealGeneration,
                  self.chromeRevealPending else { return }
            self.chromeRevealPending = false
            self.store.revealSideStageChrome()
        }
    }

    private func requestSideStageChromeHide() {
        chromeRevealPending = false
        chromeRevealGeneration += 1
        chromeHideGeneration += 1
        let generation = chromeHideGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + SideStageChromePolicy.hideDuration) { [weak self] in
            guard let self, generation == self.chromeHideGeneration else { return }
            self.store.collapseSideStage()
        }
    }

    private func invalidateSideStageChrome() {
        chromeRevealPending = false
        chromeRevealGeneration += 1
        chromeHideGeneration += 1
    }

    private func scheduleWorkspacePaneRevealOnNextFrame() {
        guard workspaceRevealPending else { return }
        let generation = workspaceRevealGeneration
        OverlayPulse.shared.onNextFrame { [weak self] in
            guard let self,
                  generation == self.workspaceRevealGeneration,
                  self.workspaceRevealPending,
                  !self.isUpdatingFrame,
                  !self.frameAnimator.isAnimating else { return }
            self.workspaceRevealPending = false
            self.store.revealWorkspacePaneContent()
            OverlayPulse.shared.onNextFrame { [weak self] in
                guard let self,
                      generation == self.workspaceRevealGeneration,
                      !self.workspaceRevealPending else { return }
                OverlayPulse.shared.onNextFrame { [weak self] in
                    guard let self,
                          generation == self.workspaceRevealGeneration else { return }
                    self.store.uncoverWorkspacePane()
                    if OverlayRenderPolicy.shouldResumeStream(
                        panelVisible: self.panel.isVisible,
                        isMoving: self.isHiding || self.frameAnimator.isAnimating
                    ) {
                        self.store.setStreamUISuspended(false)
                    }
                }
            }
        }
    }

    private var currentPreviewWidth: CGFloat {
        SideStagePolicy.width(
            showingMarkdown: store.markdownPreview != nil,
            showingWorkspace: store.workspaceStage != nil,
            markdownWidth: OverlayMetrics.previewWidth,
            workspaceWidth: OverlayMetrics.previewWidth
        )
    }

    private func rememberRestPosition(_ frame: NSRect) {
        restCenterX = frame.midX
        restBottomY = frame.minY
    }

    private func requestTranscriptWidthToggle() {
        let currentTarget = pendingTranscriptWide ?? store.transcriptWide
        let targetWide = !currentTarget
        pendingTranscriptWide = targetWide
        widthToggleGeneration += 1
        let generation = widthToggleGeneration

        var frame = targetPanelFrame ?? panel.frame
        let centerX = restCenterX ?? frame.midX
        syncVisibleScreenWidth()
        let targetWidth = OverlayMetrics.fittedTranscriptWidth(
            wide: targetWide,
            sideStageWidth: currentPreviewWidth,
            visibleWidth: store.visibleScreenWidth
        )
        let previewExtra = OverlayLayoutPolicy.previewExtraWidth(
            currentPreviewWidth,
            gap: OverlayMetrics.stackSpacing
        )
        let bleed = OverlayMetrics.shadowInset
        let contentWidth = targetWidth + previewExtra
        frame.size.width = contentWidth + bleed * 2
        frame.origin.x = OverlayLayoutPolicy.panelOriginX(
            centerX: centerX,
            contentWidth: contentWidth,
            bleed: bleed
        )
        constrainToVisibleScreens(&frame, constrainVertically: false)
        let startingWidth = panel.frame.width
        updatePanelFrame(frame, animated: panel.isVisible)

        let commit = { [weak self] in
            self?.commitTranscriptWidth(targetWide, generation: generation)
        }
        if !frameAnimator.isAnimating {
            commit()
            return
        }
        frameAnimator.onSettled = { [weak self] in
            commit()
            self?.finishFrameAnimation()
        }
        frameAnimator.onProgress = { [weak self] current, _ in
            guard let self, self.widthToggleGeneration == generation else { return }
            let totalDistance = abs(targetWidth - startingWidth)
            let commitDistance = min(60, max(24, totalDistance * 0.18))
            if abs(current.width - startingWidth) >= commitDistance {
                commit()
                self.frameAnimator.onProgress = nil
            }
        }
    }

    private func commitTranscriptWidth(_ targetWide: Bool, generation: Int) {
        guard widthToggleGeneration == generation else { return }
        if store.transcriptWide != targetWide {
            store.setTranscriptWidth(targetWide)
        }
        pendingTranscriptWide = nil
    }

    func windowDidMove(_ notification: Notification) {
        syncVisibleScreenWidth()
        guard panel.isVisible, !isUpdatingFrame, !isHiding else { return }
        rememberRestPosition(panel.frame)
        let defaults = UserDefaults.standard
        defaults.set(restCenterX ?? panel.frame.midX, forKey: positionCenterXKey)
        defaults.set(panel.frame.minY, forKey: positionBottomYKey)
    }

    func hideIfFocusLost() {
        if store.overlayPinned { return }
        if MermaidZoomController.shared.isVisible || ImageZoomController.shared.isVisible {
            return
        }
        hide()
    }

    func windowDidResignKey(_ notification: Notification) {
        hideIfFocusLost()
    }

    private func currentVisibleFrame() -> NSRect? {
        if let screen = panel.screen {
            return screen.visibleFrame
        }
        let panelCenter = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(panelCenter, $0.frame, false) }) {
            return screen.visibleFrame
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame
    }

    private func syncVisibleScreenWidth() {
        let width = currentVisibleFrame()?.width ?? 1512
        if abs(store.visibleScreenWidth - width) > 0.5 {
            store.visibleScreenWidth = width
        }
    }

    private func hideIfClickOutside() {
        guard panel.isVisible, !isHiding, !store.overlayPinned else { return }
        if MermaidZoomController.shared.containsMouse()
            || ImageZoomController.shared.containsMouse()
            || FileChangeDiffController.shared.containsMouse() {
            return
        }
        let click = NSEvent.mouseLocation
        if OverlayHitTestPolicy.shouldHide(
            panelContainsClick: panel.frame.contains(click),
            visibleCardContainsClick: rootView.containsVisibleCard(atScreenPoint: click)
        ) {
            hide()
        }
    }

    @discardableResult
    private func pasteIntoDraft() -> Bool {
        let snap = MacClipboard.snapshot()
        let intake = OverlayComposer.intake(
            text: snap.text,
            imagePNG: snap.imagePNG,
            fileURLs: snap.fileURLs
        )
        guard !intake.isEmpty else { return false }
        for png in intake.images {
            store.attachDraftImage(png)
        }
        for clip in intake.clips {
            store.attachDraftClip(clip)
        }
        if !intake.insertText.isEmpty {
            insertComposerText(intake.insertText)
        }
        store.requestFocus()
        return true
    }

    private func insertComposerNewline() {
        insertComposerText("\n")
    }

    private func insertComposerText(_ snippet: String) {
        if let textView = panel.firstResponder as? NSTextView, textView.isEditable {
            textView.insertText(snippet, replacementRange: textView.selectedRange())
            store.draft = textView.string
        } else {
            store.draft = OverlayEditCommands.insertText(
                snippet,
                into: store.draft,
                firstResponder: panel.firstResponder
            )
        }
    }

    private func handleEscape() {
        if ImageZoomController.shared.isVisible {
            ImageZoomController.shared.close()
            return
        }
        if FileChangeDiffController.shared.isVisible {
            FileChangeDiffController.shared.close()
            return
        }
        if store.handleSideStageEscape() {
            return
        }
        if MermaidZoomController.shared.isVisible {
            MermaidZoomController.shared.close()
            return
        }
        if store.slashMenuVisible {
            store.dismissSlashMenu()
        } else if store.showAvatarPicker {
            store.showAvatarPicker = false
        } else if store.isBusy {
            store.cancel()
        } else {
            hide()
        }
    }

    private func connectAllIfNeeded() {
        for runtime in sessions.allRuntimes {
            Task { @MainActor [weak self, weak runtime] in
                guard let self, let runtime else { return }
                await self.connectIfNeeded(runtime)
            }
        }
    }

    private func connectIfNeeded(_ runtime: ChatStore? = nil) async {
        let runtime = runtime ?? store
        if runtime.isConnected || connectingRuntimeIDs.contains(runtime.runtimeID) { return }
        connectingRuntimeIDs.insert(runtime.runtimeID)
        await runtime.connect()
        connectingRuntimeIDs.remove(runtime.runtimeID)
    }
}
