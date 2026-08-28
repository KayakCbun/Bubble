import AppKit
import QuartzCore
import SwiftUI

struct TranscriptRowAnchor: NSViewRepresentable {
    var id: String
    var historyTickID: String?

    func makeNSView(context: Context) -> TranscriptRowAnchorView {
        TranscriptRowAnchorView(id: id, historyTickID: historyTickID)
    }

    func updateNSView(_ view: TranscriptRowAnchorView, context: Context) {
        view.id = id
        view.historyTickID = historyTickID
    }
}

final class TranscriptRowAnchorView: NSView {
    var id: String
    var historyTickID: String?

    init(id: String, historyTickID: String?) {
        self.id = id
        self.historyTickID = historyTickID
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.post(name: .transcriptRowAnchorChanged, object: self)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.post(name: .transcriptRowAnchorChanged, object: self)
    }
}

extension Notification.Name {
    static let transcriptRowAnchorChanged = Notification.Name("BubbleTranscriptRowAnchorChanged")
    static let transcriptViewportChanged = Notification.Name("BubbleTranscriptViewportChanged")
    static let transcriptProgrammaticScrollStarted = Notification.Name(
        "BubbleTranscriptProgrammaticScrollStarted"
    )
    static let transcriptHistoryNavigationRequested = Notification.Name(
        "BubbleTranscriptHistoryNavigationRequested"
    )
    static let transcriptHistoryNavigationSettled = Notification.Name(
        "BubbleTranscriptHistoryNavigationSettled"
    )
    static let transcriptUserScrollStarted = Notification.Name("BubbleTranscriptUserScrollStarted")
}

enum TranscriptViewportUserInfoKey {
    static let visibleRowIDs = "visibleRowIDs"
    static let targetID = "targetID"
    static let atEnd = "atEnd"
}

private final class WeakTranscriptRowAnchor {
    weak var value: TranscriptRowAnchorView?

    init(_ value: TranscriptRowAnchorView) {
        self.value = value
    }
}

struct TranscriptScrollObserver: NSViewRepresentable {
    var maintainsVisibleContent: Bool
    var onContentHeightChange: () -> Void
    var onChange: (_ atEnd: Bool, _ userDriven: Bool) -> Void

    func makeNSView(context: Context) -> TranscriptScrollProbe {
        let view = TranscriptScrollProbe()
        view.onContentHeightChange = onContentHeightChange
        view.onChange = onChange
        view.setMaintainsVisibleContent(maintainsVisibleContent)
        return view
    }

    func updateNSView(_ view: TranscriptScrollProbe, context: Context) {
        view.onContentHeightChange = onContentHeightChange
        view.onChange = onChange
        view.setMaintainsVisibleContent(maintainsVisibleContent)
        view.attachWhenReady()
    }
}

final class TranscriptScrollProbe: NSView {
    private static let userEventWindow: TimeInterval = 0.35
    private static let endThreshold: CGFloat = 36
    private static let navigationKeyCodes: Set<UInt16> = [115, 116, 121, 125, 126]

    var onContentHeightChange: (() -> Void)?
    var onChange: ((_ atEnd: Bool, _ userDriven: Bool) -> Void)?
    /// AppKit virtualization owns the authoritative mounted window. Diagnostics
    /// can read it directly instead of waiting for nested SwiftUI anchor views
    /// to finish a second asynchronous mount pass after every synthetic jump.
    var visibleHistoryTickIDsProvider: (() -> Set<String>)?
    var maintainsVisibleContent = false {
        didSet {
            guard maintainsVisibleContent != oldValue else { return }
            if maintainsVisibleContent {
                DispatchQueue.main.async { [weak self] in self?.captureVisibleAnchor() }
            } else {
                visibleAnchor = nil
            }
        }
    }

    private weak var observedScrollView: NSScrollView?
    private weak var observedDocument: NSView?
    private var boundsObserver: NSObjectProtocol?
    private var documentFrameObserver: NSObjectProtocol?
    private var rowAnchorObserver: NSObjectProtocol?
    private var programmaticScrollObserver: NSObjectProtocol?
    private var historyNavigationObserver: NSObjectProtocol?
    private var eventMonitor: Any?
    private var userEventDeadline: TimeInterval = 0
    private var userSettleTimer: Timer?
    private var suppressingPriorScrollSequence = false
    private var pendingWheelDeltaY: CGFloat = 0
    private var pendingWheelHasPreciseDeltas = true
    private var wheelDisplayLink: CADisplayLink?
    private var pendingHistoryTargetID: String?
    private var historyAlignmentQueued = false
    private var historyAlignmentGeneration = 0
    private var historyAlignmentStablePasses = 0
    private var historyAlignmentLastPosition: CGFloat?
    private var visibleAnchor: (id: String, offset: CGFloat)?
    private var correctingAnchor = false
    private let diagnosticsMode = ProcessInfo.processInfo.environment["BUBBLE_SCROLL_DIAGNOSTICS"]
    private let diagnosticScrollStep = CGFloat(
        Double(ProcessInfo.processInfo.environment["BUBBLE_SCROLL_DIAGNOSTIC_STEP"] ?? "") ?? 96
    )
    private var diagnosedUserScroll = false
    private var diagnosedAnchorRestore = false
    private var rowAnchors: [ObjectIdentifier: WeakTranscriptRowAnchor] = [:]
    private var cachedHistoryAnchors: [String: (frame: CGRect, position: CGFloat)] = [:]
    private var anchorIndex: [(id: String, historyTickID: String?, frame: CGRect, position: CGFloat)] = []
    private var anchorCaptureQueued = false
    private var anchorRestoreQueued = false
    private var anchorIndexRebuildQueued = false
    private var viewportReportQueued = false
    private var diagnosticFramesRemaining = 0
    private var diagnosticDirection: CGFloat = -1
    private var diagnosticWheelBeginsGesture = true
    private var diagnosticLastTick: TimeInterval?
    private var diagnosticFrameIntervals: [TimeInterval] = []
    private var diagnosticScrollDurations: [TimeInterval] = []
    private var diagnosticMaximumWheelFlushDuration: TimeInterval = 0
    private var diagnosticMaximumReportDuration: TimeInterval = 0
    private var diagnosticInputSequenceStartedAt: TimeInterval?
    private var diagnosticInputOriginY: CGFloat?
    private var diagnosticFirstInputLatency: TimeInterval?
    private var diagnosticFirstInputMoved = false
    private var diagnosticReadyStartedAt: TimeInterval?
    private var diagnosticReadyLatency: TimeInterval = 0
    private var diagnosticPeakAnchorCount = 0
    private var diagnosticDisplayLink: CADisplayLink?
    private var diagnosticDriveTimer: Timer?
    private var diagnosticMountTimer: Timer?
    private var diagnosticMountStep = 0
    private var diagnosticMountAwaitingContent = false
    private var diagnosticBlankSamples = 0
    private var diagnosticLongestBlankStreak = 0
    private var diagnosticCurrentBlankStreak = 0
    private var diagnosticCoverageMismatches = 0
    private var lastReportedVisibleRowIDs: Set<String> = []

    private var diagnosticsEnabled: Bool { diagnosticsMode != nil }

    func setMaintainsVisibleContent(_ enabled: Bool) {
        maintainsVisibleContent = enabled || diagnosticsEnabled
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachWhenReady()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        attachWhenReady()
    }

    deinit {
        detach()
    }

    func attachWhenReady() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) { [weak self] in
            guard let self,
                  let scrollView = self.enclosingScrollView,
                  let document = scrollView.documentView else { return }
            if self.observedScrollView === scrollView,
               self.observedDocument === document { return }
            self.detach()
            self.observedScrollView = scrollView
            self.observedDocument = document
            scrollView.contentView.postsBoundsChangedNotifications = true
            document.postsFrameChangedNotifications = true
            self.boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.boundsChanged()
            }
            self.documentFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: document,
                queue: .main
            ) { [weak self] _ in
                self?.documentFrameChanged()
            }
            self.rowAnchorObserver = NotificationCenter.default.addObserver(
                forName: .transcriptRowAnchorChanged,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let anchor = notification.object as? TranscriptRowAnchorView else { return }
                self?.updateRegistration(for: anchor)
            }
            self.programmaticScrollObserver = NotificationCenter.default.addObserver(
                forName: .transcriptProgrammaticScrollStarted,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.prepareForProgrammaticScroll()
                self.cancelPendingHistoryAlignment()
            }
            self.historyNavigationObserver = NotificationCenter.default.addObserver(
                forName: .transcriptHistoryNavigationRequested,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self,
                      let targetID = note.userInfo?[TranscriptViewportUserInfoKey.targetID] as? String else {
                    return
                }
                self.prepareForProgrammaticScroll()
                self.pendingHistoryTargetID = targetID
                self.historyAlignmentGeneration += 1
                self.historyAlignmentStablePasses = 0
                self.historyAlignmentLastPosition = nil
                self.visibleAnchor = nil
                self.schedulePendingHistoryAlignment()
            }
            self.eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.scrollWheel, .leftMouseDragged, .keyDown]
            ) { [weak self] event in
                if event.type == .scrollWheel,
                   self?.handleScrollWheel(event) == true {
                    return nil
                }
                self?.recordUserEvent(event)
                return event
            }
            self.reportPosition()
            self.registerExistingAnchors(in: document)
            self.rebuildAnchorIndex()
            self.reportPosition()
            self.captureVisibleAnchor()
            if self.diagnosticsEnabled {
                OverlayLog.write("transcript scroll observer attached")
            }
            if self.diagnosticsMode == "drive"
                || self.diagnosticsMode == "wheel"
                || self.diagnosticsMode == "wheel-timer"
                || self.diagnosticsMode == "wheel-discrete-timer" {
                self.startDiagnosticDrive()
            } else if self.diagnosticsMode == "mount-audit" {
                self.startMountAudit()
            }
        }
    }

    private func detach() {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }
        if let documentFrameObserver {
            NotificationCenter.default.removeObserver(documentFrameObserver)
            self.documentFrameObserver = nil
        }
        if let rowAnchorObserver {
            NotificationCenter.default.removeObserver(rowAnchorObserver)
            self.rowAnchorObserver = nil
        }
        if let programmaticScrollObserver {
            NotificationCenter.default.removeObserver(programmaticScrollObserver)
            self.programmaticScrollObserver = nil
        }
        if let historyNavigationObserver {
            NotificationCenter.default.removeObserver(historyNavigationObserver)
            self.historyNavigationObserver = nil
        }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        observedScrollView = nil
        observedDocument = nil
        visibleAnchor = nil
        rowAnchors.removeAll()
        cachedHistoryAnchors.removeAll()
        anchorIndex.removeAll()
        anchorCaptureQueued = false
        anchorRestoreQueued = false
        anchorIndexRebuildQueued = false
        viewportReportQueued = false
        cancelPendingWheelScroll()
        cancelPendingHistoryAlignment()
        userSettleTimer?.invalidate()
        userSettleTimer = nil
        diagnosticDisplayLink?.invalidate()
        diagnosticDisplayLink = nil
        diagnosticDriveTimer?.invalidate()
        diagnosticDriveTimer = nil
        diagnosticMountTimer?.invalidate()
        diagnosticMountTimer = nil
    }

    private func recordUserEvent(_ event: NSEvent) {
        guard let scrollView = observedScrollView,
              event.window === scrollView.window else { return }
        if suppressesPriorScrollEvent(event) {
            return
        }
        if event.type == .keyDown {
            guard Self.navigationKeyCodes.contains(event.keyCode),
                  let responder = scrollView.window?.firstResponder as? NSView,
                  responder === scrollView || responder.isDescendant(of: scrollView) else { return }
        } else {
            let frameInWindow = scrollView.convert(scrollView.bounds, to: nil)
            guard frameInWindow.contains(event.locationInWindow) else { return }
        }
        recordAcceptedUserEvent()
        DispatchQueue.main.async { [weak self] in self?.reportPosition() }
    }

    /// SwiftUI's hosted `NSScrollView` can defer the first effective delta for
    /// several event cycles while it establishes a gesture. Applying AppKit's
    /// already-accelerated delta to the clip view makes the first movement
    /// synchronous while preserving trackpad momentum packets.
    @discardableResult
    private func handleScrollWheel(
        _ event: NSEvent,
        validatesLocation: Bool = true
    ) -> Bool {
        guard let scrollView = observedScrollView else { return false }
        if validatesLocation {
            guard event.window === scrollView.window else { return false }
            let frameInWindow = scrollView.convert(scrollView.bounds, to: nil)
            guard frameInWindow.contains(event.locationInWindow) else { return false }
        }
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            return false
        }
        if suppressesPriorScrollEvent(event) {
            return true
        }

        let deltaY = TranscriptWheelScrollPolicy.resolvedDelta(
            scrollingDeltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas
        )

        recordAcceptedUserEvent()
        pendingWheelHasPreciseDeltas = event.hasPreciseScrollingDeltas
        pendingWheelDeltaY = TranscriptWheelFramePolicy.queuedDelta(
            pending: pendingWheelDeltaY,
            incoming: deltaY,
            maximumPendingDelta: TranscriptWheelFramePolicy.maximumPendingDelta(
                hasPreciseDeltas: pendingWheelHasPreciseDeltas
            )
        )
        let beginsFrameSequence = wheelDisplayLink == nil
        schedulePendingWheelScroll(in: scrollView)
        if beginsFrameSequence {
            applyPendingWheelFrame()
        }
        return true
    }

    private func schedulePendingWheelScroll(in scrollView: NSScrollView) {
        guard wheelDisplayLink == nil,
              abs(pendingWheelDeltaY) > 0.01,
              let window = scrollView.window else { return }
        let link = window.displayLink(target: self, selector: #selector(flushPendingWheelScroll(_:)))
        link.preferredFrameRateRange = OverlayMotion.frameRate
        link.add(to: .main, forMode: .common)
        wheelDisplayLink = link
    }

    @objc private func flushPendingWheelScroll(_ link: CADisplayLink) {
        guard applyPendingWheelFrame() else {
            cancelPendingWheelScroll()
            return
        }

        if abs(pendingWheelDeltaY) <= 0.01 {
            link.invalidate()
            wheelDisplayLink = nil
        }
    }

    @discardableResult
    private func applyPendingWheelFrame() -> Bool {
        let diagnosticStartedAt = diagnosticsEnabled ? CACurrentMediaTime() : nil
        defer {
            if let diagnosticStartedAt {
                diagnosticMaximumWheelFlushDuration = max(
                    diagnosticMaximumWheelFlushDuration,
                    CACurrentMediaTime() - diagnosticStartedAt
                )
            }
        }
        guard let scrollView = observedScrollView,
              let document = scrollView.documentView else { return false }
        let frameStep = TranscriptWheelFramePolicy.nextFrame(
            pending: pendingWheelDeltaY,
            maximumStep: TranscriptWheelFramePolicy.maximumStep(
                hasPreciseDeltas: pendingWheelHasPreciseDeltas
            )
        )
        let visible = scrollView.contentView.bounds
        let minimumY = document.bounds.minY
        let maximumY = max(minimumY, document.bounds.maxY - visible.height)
        let nextY = min(maximumY, max(minimumY, visible.minY - frameStep.applied))
        pendingWheelDeltaY = frameStep.remaining

        if abs(nextY - visible.minY) > 0.01 {
            scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: nextY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            scheduleViewportReport()
        } else {
            pendingWheelDeltaY = 0
        }
        return true
    }

    private func cancelPendingWheelScroll() {
        pendingWheelDeltaY = 0
        pendingWheelHasPreciseDeltas = true
        wheelDisplayLink?.invalidate()
        wheelDisplayLink = nil
    }

    private func recordAcceptedUserEvent() {
        let startsUserScroll = CACurrentMediaTime() > userEventDeadline
        cancelPendingHistoryAlignment()
        deferAnchorMaintenanceUntilUserSettles()
        if startsUserScroll {
            NotificationCenter.default.post(name: .transcriptUserScrollStarted, object: self)
        }
        if diagnosticsEnabled, !diagnosedUserScroll {
            diagnosedUserScroll = true
            OverlayLog.write("transcript physical scroll observed")
        }
    }

    /// Clicking the chip can happen before a trackpad gesture has emitted its
    /// final ended and momentum events. Those belong to the gesture that
    /// preceded the click. A direct changed event means the user is actively
    /// moving the wheel/trackpad again and must interrupt the return animation
    /// even when AppKit does not emit a fresh began phase.
    private func suppressesPriorScrollEvent(_ event: NSEvent) -> Bool {
        guard suppressingPriorScrollSequence else { return false }
        let suppress = TranscriptScrollSequencePolicy.suppressesEventAfterProgrammaticScroll(
            isScrollWheel: event.type == .scrollWheel,
            beginsNewGesture: event.phase.contains(.began) || event.phase.contains(.mayBegin),
            isDiscreteWheel: event.phase.isEmpty && event.momentumPhase.isEmpty,
            isDirectChange: event.phase.contains(.changed),
            hasMomentum: !event.momentumPhase.isEmpty
        )
        if !suppress {
            suppressingPriorScrollSequence = false
        }
        return suppress
    }

    private func prepareForProgrammaticScroll() {
        cancelPendingWheelScroll()
        userEventDeadline = 0
        userSettleTimer?.invalidate()
        userSettleTimer = nil
        suppressingPriorScrollSequence = true
    }

    private func boundsChanged() {
        scheduleViewportReport()
        if maintainsVisibleContent,
           !correctingAnchor,
           CACurrentMediaTime() > userEventDeadline {
            scheduleVisibleAnchorCapture()
        }
    }

    private func deferAnchorMaintenanceUntilUserSettles() {
        visibleAnchor = nil
        userEventDeadline = CACurrentMediaTime() + Self.userEventWindow
        if let userSettleTimer {
            userSettleTimer.fireDate = Date(timeIntervalSinceNow: Self.userEventWindow)
            return
        }
        let timer = Timer(timeInterval: Self.userEventWindow, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.userSettleTimer = nil
            guard CACurrentMediaTime() >= self.userEventDeadline else { return }
            self.rebuildAnchorIndex()
            self.reportPosition()
            self.captureVisibleAnchor()
        }
        userSettleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleVisibleAnchorCapture() {
        guard !anchorCaptureQueued else { return }
        anchorCaptureQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) { [weak self] in
            guard let self else { return }
            self.anchorCaptureQueued = false
            self.captureVisibleAnchor()
        }
    }

    private func documentFrameChanged() {
        scheduleViewportReport()
        onContentHeightChange?()
        if pendingHistoryTargetID != nil {
            schedulePendingHistoryAlignment()
            return
        }
        guard maintainsVisibleContent, visibleAnchor != nil else { return }
        // Lazy row realization changes the document height while a wheel or
        // drag is still moving. Correcting the viewport in that window makes
        // AppKit lay out twice and visibly fights the gesture. Capture a fresh
        // anchor after the gesture settles; later size changes can restore it.
        if CACurrentMediaTime() <= userEventDeadline {
            return
        }
        guard !anchorRestoreQueued else { return }
        anchorRestoreQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) { [weak self] in
            guard let self else { return }
            self.anchorRestoreQueued = false
            self.rebuildAnchorIndex()
            self.restoreVisibleAnchor()
        }
    }

    private func reportPosition() {
        let diagnosticStartedAt = diagnosticsEnabled ? CACurrentMediaTime() : nil
        defer {
            if let diagnosticStartedAt {
                diagnosticMaximumReportDuration = max(
                    diagnosticMaximumReportDuration,
                    CACurrentMediaTime() - diagnosticStartedAt
                )
            }
        }
        guard let scrollView = observedScrollView,
              let document = scrollView.documentView else { return }
        let visible = scrollView.contentView.bounds
        let distanceToEnd = document.isFlipped
            ? document.bounds.maxY - visible.maxY
            : visible.minY - document.bounds.minY
        let atEnd = distanceToEnd <= Self.endThreshold
        let userDriven = CACurrentMediaTime() <= userEventDeadline
        onChange?(atEnd, userDriven)

        let visibleRowIDs = diagnosticVisibleHistoryTickIDs(in: visible, document: document)
        if diagnosticsMode == "mount-audit",
           visibleHistoryTickIDsProvider == nil,
           visibleRowIDs != hierarchyVisibleHistoryTickIDs(in: visible, document: document) {
            diagnosticCoverageMismatches += 1
        }
        if visibleRowIDs != lastReportedVisibleRowIDs {
            lastReportedVisibleRowIDs = visibleRowIDs
            NotificationCenter.default.post(
                name: .transcriptViewportChanged,
                object: self,
                userInfo: [
                    TranscriptViewportUserInfoKey.visibleRowIDs: Array(visibleRowIDs),
                ]
            )
        }
    }

    private func captureVisibleAnchor() {
        guard maintainsVisibleContent,
              let scrollView = observedScrollView,
              let document = observedDocument else { return }
        let visible = scrollView.contentView.bounds
        let visibleCandidates = visibleAnchorCandidates(in: visible)
        let anchor = visibleCandidates
            .min(by: { abs($0.position - visibleEdge(visible, document: document))
                < abs($1.position - visibleEdge(visible, document: document)) })
            ?? anchorIndex.last(where: { $0.frame.minY <= visible.minY })
            ?? anchorIndex.first
        guard let anchor else { return }
        visibleAnchor = (
            id: anchor.id,
            offset: anchor.position - visibleEdge(visible, document: document)
        )
    }

    private func restoreVisibleAnchor() {
        guard maintainsVisibleContent,
              !correctingAnchor,
              let visibleAnchor,
              let scrollView = observedScrollView,
              let document = observedDocument,
              let anchor = anchorIndex.first(where: { $0.id == visibleAnchor.id }) else {
            return
        }
        let visible = scrollView.contentView.bounds
        let desiredOriginY = TranscriptViewportAnchorPolicy.visibleOrigin(
            anchorPosition: anchor.position,
            anchorOffset: visibleAnchor.offset,
            visibleHeight: visible.height,
            documentIsFlipped: document.isFlipped
        )
        guard abs(desiredOriginY - visible.minY) > 0.5 else { return }
        correctingAnchor = true
        scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: desiredOriginY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        correctingAnchor = false
        if diagnosticsEnabled, !diagnosedAnchorRestore {
            diagnosedAnchorRestore = true
            OverlayLog.write("transcript visible anchor restored")
        }
    }

    private func visibleEdge(_ visible: CGRect, document: NSView) -> CGFloat {
        document.isFlipped ? visible.minY : visible.maxY
    }

    private func rebuildAnchorIndex() {
        guard let document = observedDocument else {
            anchorIndex = []
            return
        }
        rowAnchors = rowAnchors.filter { _, weakAnchor in
            guard let anchor = weakAnchor.value else { return false }
            return anchor.window != nil && anchor.enclosingScrollView === observedScrollView
        }
        let liveAnchors = rowAnchors.values.compactMap { weakAnchor -> (
            id: String,
            historyTickID: String?,
            frame: CGRect,
            position: CGFloat
        )? in
            guard let anchor = weakAnchor.value else { return nil }
            let frame = anchor.convert(anchor.bounds, to: document)
            return (
                anchor.id,
                anchor.historyTickID,
                frame,
                document.isFlipped ? frame.minY : frame.maxY
            )
        }
        for anchor in liveAnchors {
            cachedHistoryAnchors[anchor.historyTickID ?? anchor.id] = (
                anchor.frame,
                anchor.position
            )
        }
        anchorIndex = cachedHistoryAnchors.map { id, cached in
            (id, Optional(id), cached.frame, cached.position)
        }
        .sorted { $0.frame.minY < $1.frame.minY }
        diagnosticPeakAnchorCount = max(diagnosticPeakAnchorCount, rowAnchors.count)
    }

    private func visibleAnchorCandidates(in visible: CGRect) -> ArraySlice<(
        id: String,
        historyTickID: String?,
        frame: CGRect,
        position: CGFloat
    )> {
        var lower = 0
        var upper = anchorIndex.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if anchorIndex[middle].frame.maxY < visible.minY {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        var end = lower
        while end < anchorIndex.count, anchorIndex[end].frame.minY <= visible.maxY {
            end += 1
        }
        return anchorIndex[lower..<end]
    }

    private func updateRegistration(for anchor: TranscriptRowAnchorView) {
        let key = ObjectIdentifier(anchor)
        if anchor.window != nil, anchor.enclosingScrollView === observedScrollView {
            rowAnchors[key] = WeakTranscriptRowAnchor(anchor)
        } else {
            rowAnchors.removeValue(forKey: key)
        }
        scheduleViewportReport()
        if anchor.id == pendingHistoryTargetID {
            schedulePendingHistoryAlignment()
        }
        if CACurrentMediaTime() > userEventDeadline {
            scheduleAnchorIndexRebuild()
        }
    }

    private func scheduleViewportReport() {
        guard !viewportReportQueued else { return }
        viewportReportQueued = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + TranscriptViewportReportPolicy.minimumInterval
        ) { [weak self] in
            guard let self else { return }
            self.viewportReportQueued = false
            self.reportPosition()
        }
    }

    private func schedulePendingHistoryAlignment() {
        guard !historyAlignmentQueued, pendingHistoryTargetID != nil else { return }
        historyAlignmentQueued = true
        let generation = historyAlignmentGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) { [weak self] in
            guard let self else { return }
            self.historyAlignmentQueued = false
            guard generation == self.historyAlignmentGeneration else { return }
            self.alignPendingHistoryTarget(generation: generation)
        }
    }

    private func alignPendingHistoryTarget(generation: Int) {
        guard generation == historyAlignmentGeneration,
              let targetID = pendingHistoryTargetID,
              let scrollView = observedScrollView,
              let document = observedDocument,
              let target = anchorIndex.first(where: { $0.id == targetID }) else { return }
        let frame = target.frame
        let visible = scrollView.contentView.bounds
        let minimumY = document.bounds.minY
        let maximumY = max(minimumY, document.bounds.maxY - visible.height)
        let rawTargetY = document.isFlipped ? frame.minY : frame.maxY - visible.height
        let targetY = min(maximumY, max(minimumY, rawTargetY))
        if abs(visible.minY - targetY) > 0.5 {
            scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        guard let stableFrame = anchorIndex.first(where: { $0.id == targetID })?.frame else { return }
        let stablePosition = document.isFlipped ? stableFrame.minY : stableFrame.maxY
        let frameStable = historyAlignmentLastPosition.map { abs($0 - stablePosition) <= 0.5 } ?? false
        let viewportStable = abs(scrollView.contentView.bounds.minY - targetY) <= 0.5
        historyAlignmentLastPosition = stablePosition
        historyAlignmentStablePasses = frameStable && viewportStable
            ? historyAlignmentStablePasses + 1
            : 0
        reportPosition()
        guard historyAlignmentStablePasses >= 2 else {
            schedulePendingHistoryAlignment()
            return
        }
        let distanceToEnd = document.isFlipped
            ? document.bounds.maxY - scrollView.contentView.bounds.maxY
            : scrollView.contentView.bounds.minY - document.bounds.minY
        let finalOffset = document.isFlipped
            ? stableFrame.minY - scrollView.contentView.bounds.minY
            : scrollView.contentView.bounds.maxY - stableFrame.maxY
        pendingHistoryTargetID = nil
        historyAlignmentLastPosition = nil
        if diagnosticsMode == "history-navigation-audit" {
            OverlayLog.write(
                String(
                    format: "history navigation audit target=%@ offset=%.2f atEnd=%d",
                    targetID,
                    finalOffset,
                    distanceToEnd <= Self.endThreshold ? 1 : 0
                )
            )
        }
        NotificationCenter.default.post(
            name: .transcriptHistoryNavigationSettled,
            object: self,
            userInfo: [
                TranscriptViewportUserInfoKey.targetID: targetID,
                TranscriptViewportUserInfoKey.atEnd: distanceToEnd <= Self.endThreshold,
            ]
        )
    }

    private func cancelPendingHistoryAlignment() {
        pendingHistoryTargetID = nil
        historyAlignmentGeneration += 1
        historyAlignmentStablePasses = 0
        historyAlignmentLastPosition = nil
    }

    private func scheduleAnchorIndexRebuild() {
        guard !anchorIndexRebuildQueued else { return }
        anchorIndexRebuildQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) { [weak self] in
            guard let self else { return }
            self.anchorIndexRebuildQueued = false
            self.rebuildAnchorIndex()
            self.reportPosition()
        }
    }

    private func registerExistingAnchors(in root: NSView) {
        var pending = root.subviews
        while let view = pending.popLast() {
            if let anchor = view as? TranscriptRowAnchorView {
                updateRegistration(for: anchor)
            } else {
                pending.append(contentsOf: view.subviews)
            }
        }
    }

    private func startDiagnosticDrive() {
        guard diagnosticFramesRemaining == 0,
              let window else { return }
        diagnosticFramesRemaining = -1
        diagnosticReadyStartedAt = TranscriptHydrationTiming.diagnosticStartedAt
            ?? ProcessInfo.processInfo.systemUptime
        NSRunningApplication.current.activate()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.beginDiagnosticDrive(in: window)
        }
    }

    private func beginDiagnosticDrive(in window: NSWindow) {
        if TranscriptHydrationTiming.diagnosticStartedAt != nil,
           !TranscriptHydrationTiming.diagnosticHydrationCompleted,
           let startedAt = diagnosticReadyStartedAt,
           ProcessInfo.processInfo.systemUptime - startedAt < 15 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window] in
                guard let self, let window else { return }
                self.beginDiagnosticDrive(in: window)
            }
            return
        }
        if let document = observedDocument {
            registerExistingAnchors(in: document)
            rebuildAnchorIndex()
        }
        if !anchorIndex.contains(where: { $0.historyTickID != nil }),
           let startedAt = diagnosticReadyStartedAt,
           ProcessInfo.processInfo.systemUptime - startedAt < 15 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window] in
                guard let self, let window else { return }
                self.beginDiagnosticDrive(in: window)
            }
            return
        }
        diagnosticReadyLatency = diagnosticReadyStartedAt.map {
            ProcessInfo.processInfo.systemUptime - $0
        } ?? 0
        diagnosticReadyStartedAt = nil
        TranscriptHydrationTiming.clear()
        maintainsVisibleContent = true
        diagnosticFramesRemaining = 720
        diagnosticWheelBeginsGesture = true
        diagnosticFrameIntervals.removeAll(keepingCapacity: true)
        diagnosticScrollDurations.removeAll(keepingCapacity: true)
        diagnosticMaximumWheelFlushDuration = 0
        diagnosticMaximumReportDuration = 0
        diagnosticInputSequenceStartedAt = nil
        diagnosticInputOriginY = nil
        diagnosticFirstInputLatency = nil
        diagnosticFirstInputMoved = false
        diagnosticLastTick = nil
        diagnosticPeakAnchorCount = anchorIndex.count
        diagnosticBlankSamples = 0
        diagnosticLongestBlankStreak = 0
        diagnosticCurrentBlankStreak = 0
        diagnosticCoverageMismatches = 0
        visibleAnchor = nil
        userEventDeadline = CACurrentMediaTime() + 120
        if diagnosticsMode == "wheel-timer" || diagnosticsMode == "wheel-discrete-timer" {
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
                guard self?.performDiagnosticTick() == true else {
                    timer.invalidate()
                    self?.diagnosticDriveTimer = nil
                    return
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            diagnosticDriveTimer = timer
        } else {
            let link = window.displayLink(target: self, selector: #selector(diagnosticTick(_:)))
            link.preferredFrameRateRange = OverlayMotion.frameRate
            link.add(to: .main, forMode: .common)
            diagnosticDisplayLink = link
        }
    }

    private func startMountAudit() {
        guard diagnosticMountTimer == nil else { return }
        if let document = observedDocument {
            registerExistingAnchors(in: document)
            rebuildAnchorIndex()
        }
        if anchorIndex.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.startMountAudit()
            }
            return
        }
        maintainsVisibleContent = true
        diagnosticMountStep = 0
        diagnosticMountAwaitingContent = false
        diagnosticPeakAnchorCount = anchorIndex.count
        diagnosticBlankSamples = 0
        diagnosticLongestBlankStreak = 0
        diagnosticCurrentBlankStreak = 0
        diagnosticCoverageMismatches = 0
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            self?.mountAuditTick(timer)
        }
        RunLoop.main.add(timer, forMode: .common)
        diagnosticMountTimer = timer
    }

    private func mountAuditTick(_ timer: Timer) {
        guard let scrollView = observedScrollView,
              let document = observedDocument else {
            timer.invalidate()
            diagnosticMountTimer = nil
            return
        }
        let sampleCount = 600
        if diagnosticMountStep >= sampleCount {
            timer.invalidate()
            diagnosticMountTimer = nil
            let visible = scrollView.contentView.bounds
            let maximumY = max(document.bounds.minY, document.bounds.maxY - visible.height)
            scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: document.bounds.minY + (maximumY - document.bounds.minY) * 0.5))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.finishMountAudit(sampleCount: sampleCount)
            }
            return
        }
        if !diagnosticMountAwaitingContent {
            let visible = scrollView.contentView.bounds
            let maximumY = max(document.bounds.minY, document.bounds.maxY - visible.height)
            let progress = CGFloat(diagnosticMountStep) / CGFloat(max(1, sampleCount - 1))
            let nextY = document.bounds.minY + (maximumY - document.bounds.minY) * progress
            scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: nextY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            diagnosticMountAwaitingContent = true
        } else {
            // SwiftUI may insert a lazy row before its AppKit move notification
            // is delivered. Audit the actual mounted hierarchy so a delayed
            // registration cannot be mistaken for a blank viewport.
            registerExistingAnchors(in: document)
            let visible = scrollView.contentView.bounds
            reportPosition()
            rebuildAnchorIndex()
            if diagnosticVisibleHistoryTickIDs(in: visible, document: document).isEmpty {
                diagnosticBlankSamples += 1
                diagnosticCurrentBlankStreak += 1
                diagnosticLongestBlankStreak = max(
                    diagnosticLongestBlankStreak,
                    diagnosticCurrentBlankStreak
                )
            } else {
                diagnosticCurrentBlankStreak = 0
                diagnosticMountAwaitingContent = false
                diagnosticMountStep += 1
            }
        }
    }

    /// Independent audit oracle for the viewport payload. Production reporting
    /// uses the weak anchor registry; this walks the mounted AppKit hierarchy so
    /// missed registrations, stale IDs, and bad registry geometry remain visible.
    private func hierarchyVisibleHistoryTickIDs(
        in visible: CGRect,
        document: NSView
    ) -> Set<String> {
        return visibleHistoryTickIDs(
            anchors: anchorIndex.map { ($0.historyTickID ?? $0.id, $0.frame) },
            visible: visible,
            documentMaxY: document.bounds.maxY
        )
    }

    private func finishMountAudit(sampleCount: Int) {
        guard let scrollView = observedScrollView,
              let document = observedDocument else { return }
        rebuildAnchorIndex()
        guard let anchor = anchorIndex.min(by: {
            abs($0.position - visibleEdge(scrollView.contentView.bounds, document: document))
                < abs($1.position - visibleEdge(scrollView.contentView.bounds, document: document))
        }) else {
            logMountAudit(sampleCount: sampleCount, document: document, anchorError: .infinity)
            return
        }
        let visible = scrollView.contentView.bounds
        let maximumY = max(document.bounds.minY, document.bounds.maxY - visible.height)
        let alignedY = document.isFlipped ? anchor.position - 100 : anchor.position - visible.height + 100
        scrollView.contentView.scroll(
            to: NSPoint(x: visible.minX, y: min(maximumY, max(document.bounds.minY, alignedY)))
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let alignedVisible = scrollView.contentView.bounds
        let capturedOffset = anchor.position - visibleEdge(alignedVisible, document: document)
        visibleAnchor = (anchor.id, capturedOffset)
        let displacedY = min(maximumY, alignedVisible.minY + 80)
        scrollView.contentView.scroll(to: NSPoint(x: alignedVisible.minX, y: displacedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        restoreVisibleAnchor()
        let restoredVisible = scrollView.contentView.bounds
        let anchorError = abs(
            (anchor.position - visibleEdge(restoredVisible, document: document)) - capturedOffset
        )
        logMountAudit(sampleCount: sampleCount, document: document, anchorError: anchorError)
    }

    private func logMountAudit(sampleCount: Int, document: NSView, anchorError: CGFloat) {
        OverlayLog.write(
            String(
                format: "transcript mount audit samples=%d anchors=%d peakAnchors=%d blankSamples=%d longestBlankStreak=%d coverageMismatches=%d documentHeight=%.0f anchorError=%.2f",
                sampleCount,
                rowAnchors.count,
                diagnosticPeakAnchorCount,
                diagnosticBlankSamples,
                diagnosticLongestBlankStreak,
                diagnosticCoverageMismatches,
                document.bounds.height,
                anchorError
            )
        )
    }

    @objc private func diagnosticTick(_ link: CADisplayLink) {
        guard performDiagnosticTick() else {
            link.invalidate()
            diagnosticDisplayLink = nil
            return
        }
    }

    private func performDiagnosticTick() -> Bool {
        guard diagnosticFramesRemaining > 0,
              let scrollView = observedScrollView,
              let document = observedDocument else {
            return false
        }
        let now = CACurrentMediaTime()
        if !diagnosticFirstInputMoved,
           let startedAt = diagnosticInputSequenceStartedAt,
           let originY = diagnosticInputOriginY,
           abs(scrollView.contentView.bounds.minY - originY) > 0.5 {
            diagnosticFirstInputLatency = now - startedAt
            diagnosticFirstInputMoved = true
        }
        if let last = diagnosticLastTick {
            diagnosticFrameIntervals.append(now - last)
            let visible = scrollView.contentView.bounds
            if mountedAnchorIntersects(visible, in: document) {
                diagnosticCurrentBlankStreak = 0
            } else {
                diagnosticBlankSamples += 1
                diagnosticCurrentBlankStreak += 1
                diagnosticLongestBlankStreak = max(
                    diagnosticLongestBlankStreak,
                    diagnosticCurrentBlankStreak
                )
            }
        }
        diagnosticLastTick = now

        let visible = scrollView.contentView.bounds
        let minimumY = document.bounds.minY
        let maximumY = max(minimumY, document.bounds.maxY - visible.height)
        var nextY = visible.minY + diagnosticDirection * diagnosticScrollStep
        if nextY <= minimumY || nextY >= maximumY {
            diagnosticDirection *= -1
            diagnosticWheelBeginsGesture = true
            nextY = min(
                maximumY,
                max(minimumY, visible.minY + diagnosticDirection * diagnosticScrollStep)
            )
        }
        if (diagnosticsMode == "wheel"
                || diagnosticsMode == "wheel-timer"
                || diagnosticsMode == "wheel-discrete-timer"),
           let cgEvent = CGEvent(
               scrollWheelEvent2Source: nil,
               units: diagnosticsMode == "wheel-discrete-timer" ? .line : .pixel,
               wheelCount: 1,
               wheel1: Int32(-diagnosticDirection * diagnosticScrollStep),
               wheel2: 0,
               wheel3: 0
           ) {
            if diagnosticsMode != "wheel-discrete-timer" {
                cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cgEvent.setIntegerValueField(
                    .scrollWheelEventScrollPhase,
                    value: Int64(
                        (diagnosticWheelBeginsGesture ? CGScrollPhase.began : .changed).rawValue
                    )
                )
            }
            diagnosticWheelBeginsGesture = false
            guard let event = NSEvent(cgEvent: cgEvent) else { return true }
            let originBeforeInput = scrollView.contentView.bounds.minY
            let inputStartedAt = CACurrentMediaTime()
            if diagnosticInputSequenceStartedAt == nil {
                diagnosticInputSequenceStartedAt = inputStartedAt
                diagnosticInputOriginY = originBeforeInput
            }
            if let appKitSurface = scrollView as? AppKitTranscriptScrollView {
                // Exercise the production transcript entry point.  The
                // observer's legacy wheel queue belongs to the retired
                // SwiftUI scroll surface and would benchmark code that users
                // no longer hit after the AppKit migration.
                appKitSurface.scrollWheel(with: event)
            } else {
                _ = handleScrollWheel(event, validatesLocation: false)
            }
            let inputLatency = CACurrentMediaTime() - inputStartedAt
            diagnosticScrollDurations.append(inputLatency)
            if !diagnosticFirstInputMoved,
               let startedAt = diagnosticInputSequenceStartedAt,
               let originY = diagnosticInputOriginY,
               abs(scrollView.contentView.bounds.minY - originY) > 0.5 {
                diagnosticFirstInputLatency = CACurrentMediaTime() - startedAt
                diagnosticFirstInputMoved = true
            }
        } else {
            scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: nextY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        diagnosticFramesRemaining -= 1

        if diagnosticFramesRemaining == 0 {
            let sorted = diagnosticFrameIntervals.sorted()
            let p95Index = min(max(0, Int(Double(sorted.count) * 0.95)), max(0, sorted.count - 1))
            let p99Index = min(max(0, Int(Double(sorted.count) * 0.99)), max(0, sorted.count - 1))
            let p95 = sorted.isEmpty ? 0 : sorted[p95Index] * 1_000
            let p99 = sorted.isEmpty ? 0 : sorted[p99Index] * 1_000
            let maximum = (sorted.last ?? 0) * 1_000
            let sortedScrollDurations = diagnosticScrollDurations.sorted()
            let wheelP95Index = min(
                max(0, Int(Double(sortedScrollDurations.count) * 0.95)),
                max(0, sortedScrollDurations.count - 1)
            )
            let wheelP95 = sortedScrollDurations.isEmpty
                ? 0
                : sortedScrollDurations[wheelP95Index] * 1_000
            let wheelMaximum = (sortedScrollDurations.last ?? 0) * 1_000
            OverlayLog.write(
                String(
                    format: "transcript scroll benchmark frames=%d step=%.0f ready=%.2fms p95=%.2fms p99=%.2fms max=%.2fms firstInput=%.2fms firstMoved=%d wheelP95=%.2fms wheelMax=%.2fms flushMax=%.2fms reportMax=%.2fms anchors=%d peakAnchors=%d blankFrames=%d longestBlankStreak=%d",
                    diagnosticFrameIntervals.count,
                    diagnosticScrollStep,
                    diagnosticReadyLatency * 1_000,
                    p95,
                    p99,
                    maximum,
                    (diagnosticFirstInputLatency ?? 0) * 1_000,
                    diagnosticFirstInputMoved ? 1 : 0,
                    wheelP95,
                    wheelMaximum,
                    diagnosticMaximumWheelFlushDuration * 1_000,
                    diagnosticMaximumReportDuration * 1_000,
                    rowAnchors.count,
                    diagnosticPeakAnchorCount,
                    diagnosticBlankSamples,
                    diagnosticLongestBlankStreak
                )
            )
            userEventDeadline = 0
            rebuildAnchorIndex()
            captureVisibleAnchor()
            return false
        }
        return true
    }

    private func mountedAnchorIntersects(_ visible: CGRect, in document: NSView) -> Bool {
        !diagnosticVisibleHistoryTickIDs(in: visible, document: document).isEmpty
    }

    private func liveVisibleHistoryTickIDs(in visible: CGRect, document: NSView) -> Set<String> {
        _ = document
        // `anchorIndex` is already frame-sorted. The old diagnostic path
        // rebuilt and sorted the entire long-session anchor array on every
        // display-link tick, adding O(N log N) work that production's AppKit
        // viewport never performs.
        return Set(visibleAnchorCandidates(in: visible).map {
            $0.historyTickID ?? $0.id
        })
    }

    private func diagnosticVisibleHistoryTickIDs(in visible: CGRect, document: NSView) -> Set<String> {
        visibleHistoryTickIDsProvider?() ?? liveVisibleHistoryTickIDs(in: visible, document: document)
    }

    private func visibleHistoryTickIDs(
        anchors: [(id: String, frame: CGRect)],
        visible: CGRect,
        documentMaxY: CGFloat
    ) -> Set<String> {
        let sorted = anchors.sorted { $0.frame.minY < $1.frame.minY }
        let indexes = HistoryRailPolicy.visibleTurnIndexes(
            turnStarts: sorted.map(\.frame.minY),
            documentMaxY: documentMaxY,
            viewportMinY: visible.minY,
            viewportMaxY: visible.maxY
        )
        return Set(indexes.map { sorted[$0].id })
    }
}
