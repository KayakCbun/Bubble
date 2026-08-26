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
}

enum TranscriptViewportUserInfoKey {
    static let visibleRowIDs = "visibleRowIDs"
}

private final class WeakTranscriptRowAnchor {
    weak var value: TranscriptRowAnchorView?

    init(_ value: TranscriptRowAnchorView) {
        self.value = value
    }
}

struct TranscriptScrollObserver: NSViewRepresentable {
    var maintainsVisibleContent: Bool
    var onChange: (_ atEnd: Bool, _ userDriven: Bool) -> Void

    func makeNSView(context: Context) -> TranscriptScrollProbe {
        let view = TranscriptScrollProbe()
        view.onChange = onChange
        view.setMaintainsVisibleContent(maintainsVisibleContent)
        return view
    }

    func updateNSView(_ view: TranscriptScrollProbe, context: Context) {
        view.onChange = onChange
        view.setMaintainsVisibleContent(maintainsVisibleContent)
        view.attachWhenReady()
    }
}

final class TranscriptScrollProbe: NSView {
    private static let userEventWindow: TimeInterval = 0.35
    private static let endThreshold: CGFloat = 36
    private static let navigationKeyCodes: Set<UInt16> = [115, 116, 121, 125, 126]

    var onChange: ((_ atEnd: Bool, _ userDriven: Bool) -> Void)?
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
    private var eventMonitor: Any?
    private var userEventDeadline: TimeInterval = 0
    private var userEventGeneration = 0
    private var suppressingPriorScrollSequence = false
    private var visibleAnchor: (id: String, offset: CGFloat)?
    private var correctingAnchor = false
    private let diagnosticsMode = ProcessInfo.processInfo.environment["BUBBLE_SCROLL_DIAGNOSTICS"]
    private let diagnosticScrollStep = CGFloat(
        Double(ProcessInfo.processInfo.environment["BUBBLE_SCROLL_DIAGNOSTIC_STEP"] ?? "") ?? 96
    )
    private var diagnosedUserScroll = false
    private var diagnosedAnchorRestore = false
    private var rowAnchors: [ObjectIdentifier: WeakTranscriptRowAnchor] = [:]
    private var anchorIndex: [(id: String, historyTickID: String?, frame: CGRect, position: CGFloat)] = []
    private var anchorCaptureQueued = false
    private var anchorRestoreQueued = false
    private var anchorIndexRebuildQueued = false
    private var diagnosticFramesRemaining = 0
    private var diagnosticDirection: CGFloat = -1
    private var diagnosticLastTick: TimeInterval?
    private var diagnosticFrameIntervals: [TimeInterval] = []
    private var diagnosticPeakAnchorCount = 0
    private var diagnosticDisplayLink: CADisplayLink?
    private var diagnosticMountTimer: Timer?
    private var diagnosticMountStep = 0
    private var diagnosticMountAwaitingContent = false
    private var diagnosticBlankSamples = 0
    private var diagnosticLongestBlankStreak = 0
    private var diagnosticCurrentBlankStreak = 0
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
                self.userEventDeadline = 0
                self.userEventGeneration += 1
                self.suppressingPriorScrollSequence = true
            }
            self.eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.scrollWheel, .leftMouseDragged, .keyDown]
            ) { [weak self] event in
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
            if self.diagnosticsMode == "drive" {
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
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        observedScrollView = nil
        observedDocument = nil
        visibleAnchor = nil
        rowAnchors.removeAll()
        anchorIndex.removeAll()
        anchorCaptureQueued = false
        anchorRestoreQueued = false
        anchorIndexRebuildQueued = false
        userEventGeneration += 1
        diagnosticDisplayLink?.invalidate()
        diagnosticDisplayLink = nil
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
        deferAnchorMaintenanceUntilUserSettles()
        if diagnosticsEnabled, !diagnosedUserScroll {
            diagnosedUserScroll = true
            OverlayLog.write("transcript physical scroll observed")
        }
        DispatchQueue.main.async { [weak self] in self?.reportPosition() }
    }

    /// Clicking the chip can happen before a trackpad gesture has emitted its
    /// final changed/ended and momentum events. Those belong to the gesture
    /// that preceded the click; only a new began phase (or a discrete wheel,
    /// key, or drag event) is allowed to interrupt the return animation.
    private func suppressesPriorScrollEvent(_ event: NSEvent) -> Bool {
        guard suppressingPriorScrollSequence else { return false }
        guard event.type == .scrollWheel else {
            suppressingPriorScrollSequence = false
            return false
        }
        let beginsNewGesture = event.phase.contains(.began) || event.phase.contains(.mayBegin)
        let isDiscreteWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
        if beginsNewGesture || isDiscreteWheel {
            suppressingPriorScrollSequence = false
            return false
        }
        return true
    }

    private func boundsChanged() {
        reportPosition()
        if maintainsVisibleContent,
           !correctingAnchor,
           CACurrentMediaTime() > userEventDeadline {
            scheduleVisibleAnchorCapture()
        }
    }

    private func deferAnchorMaintenanceUntilUserSettles() {
        visibleAnchor = nil
        userEventDeadline = CACurrentMediaTime() + Self.userEventWindow
        userEventGeneration += 1
        let generation = userEventGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.userEventWindow) { [weak self] in
            guard let self,
                  generation == self.userEventGeneration,
                  CACurrentMediaTime() >= self.userEventDeadline else { return }
            self.rebuildAnchorIndex()
            self.reportPosition()
            self.captureVisibleAnchor()
        }
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
        guard let scrollView = observedScrollView,
              let document = scrollView.documentView else { return }
        let visible = scrollView.contentView.bounds
        let distanceToEnd = document.isFlipped
            ? document.bounds.maxY - visible.maxY
            : visible.minY - document.bounds.minY
        let atEnd = distanceToEnd <= Self.endThreshold
        let userDriven = CACurrentMediaTime() <= userEventDeadline
        onChange?(atEnd, userDriven)

        let visibleRowIDs: Set<String> = Set(visibleAnchorCandidates(in: visible).compactMap { anchor -> String? in
            guard HistoryRailPolicy.intersectsViewport(
                rowMinY: anchor.frame.minY,
                rowMaxY: anchor.frame.maxY,
                viewportMinY: visible.minY,
                viewportMaxY: visible.maxY
            ) else { return nil }
            return anchor.historyTickID ?? anchor.id
        })
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
        guard let anchor = visibleAnchorCandidates(in: visible)
            .min(by: { abs($0.position - visibleEdge(visible, document: document))
                < abs($1.position - visibleEdge(visible, document: document)) }) else { return }
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
        anchorIndex = rowAnchors.values.compactMap { weakAnchor in
            guard let anchor = weakAnchor.value else { return nil }
            let frame = anchor.convert(anchor.bounds, to: document)
            return (
                anchor.id,
                anchor.historyTickID,
                frame,
                document.isFlipped ? frame.minY : frame.maxY
            )
        }
        .sorted { $0.frame.minY < $1.frame.minY }
        diagnosticPeakAnchorCount = max(diagnosticPeakAnchorCount, anchorIndex.count)
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
        if CACurrentMediaTime() > userEventDeadline {
            scheduleAnchorIndexRebuild()
        }
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
        NSRunningApplication.current.activate()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak window] in
            guard let self, let window else { return }
            self.beginDiagnosticDrive(in: window)
        }
    }

    private func beginDiagnosticDrive(in window: NSWindow) {
        maintainsVisibleContent = true
        diagnosticFramesRemaining = 720
        diagnosticFrameIntervals.removeAll(keepingCapacity: true)
        diagnosticLastTick = nil
        diagnosticPeakAnchorCount = anchorIndex.count
        diagnosticBlankSamples = 0
        diagnosticLongestBlankStreak = 0
        diagnosticCurrentBlankStreak = 0
        visibleAnchor = nil
        userEventDeadline = CACurrentMediaTime() + 120
        let link = window.displayLink(target: self, selector: #selector(diagnosticTick(_:)))
        link.preferredFrameRateRange = OverlayMotion.frameRate
        link.add(to: .main, forMode: .common)
        diagnosticDisplayLink = link
    }

    private func startMountAudit() {
        guard diagnosticMountTimer == nil else { return }
        maintainsVisibleContent = true
        diagnosticMountStep = 0
        diagnosticMountAwaitingContent = false
        diagnosticPeakAnchorCount = anchorIndex.count
        diagnosticBlankSamples = 0
        diagnosticLongestBlankStreak = 0
        diagnosticCurrentBlankStreak = 0
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
            rebuildAnchorIndex()
            let visible = scrollView.contentView.bounds
            if visibleAnchorCandidates(in: visible).isEmpty {
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
                format: "transcript mount audit samples=%d anchors=%d peakAnchors=%d blankSamples=%d longestBlankStreak=%d documentHeight=%.0f anchorError=%.2f",
                sampleCount,
                anchorIndex.count,
                diagnosticPeakAnchorCount,
                diagnosticBlankSamples,
                diagnosticLongestBlankStreak,
                document.bounds.height,
                anchorError
            )
        )
    }

    @objc private func diagnosticTick(_ link: CADisplayLink) {
        guard diagnosticFramesRemaining > 0,
              let scrollView = observedScrollView,
              let document = observedDocument else {
            link.invalidate()
            diagnosticDisplayLink = nil
            return
        }
        let now = CACurrentMediaTime()
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
            nextY = min(
                maximumY,
                max(minimumY, visible.minY + diagnosticDirection * diagnosticScrollStep)
            )
        }
        scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: nextY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        diagnosticFramesRemaining -= 1

        if diagnosticFramesRemaining == 0 {
            let sorted = diagnosticFrameIntervals.sorted()
            let p95Index = min(max(0, Int(Double(sorted.count) * 0.95)), max(0, sorted.count - 1))
            let p99Index = min(max(0, Int(Double(sorted.count) * 0.99)), max(0, sorted.count - 1))
            let p95 = sorted.isEmpty ? 0 : sorted[p95Index] * 1_000
            let p99 = sorted.isEmpty ? 0 : sorted[p99Index] * 1_000
            let maximum = (sorted.last ?? 0) * 1_000
            OverlayLog.write(
                String(
                    format: "transcript scroll benchmark frames=%d step=%.0f p95=%.2fms p99=%.2fms max=%.2fms anchors=%d peakAnchors=%d blankFrames=%d longestBlankStreak=%d",
                    diagnosticFrameIntervals.count,
                    diagnosticScrollStep,
                    p95,
                    p99,
                    maximum,
                    anchorIndex.count,
                    diagnosticPeakAnchorCount,
                    diagnosticBlankSamples,
                    diagnosticLongestBlankStreak
                )
            )
            userEventDeadline = 0
            rebuildAnchorIndex()
            captureVisibleAnchor()
            link.invalidate()
            diagnosticDisplayLink = nil
            return
        }
    }

    private func mountedAnchorIntersects(_ visible: CGRect, in document: NSView) -> Bool {
        rowAnchors.values.contains { weakAnchor in
            guard let anchor = weakAnchor.value,
                  anchor.window != nil,
                  anchor.enclosingScrollView === observedScrollView else { return false }
            return anchor.convert(anchor.bounds, to: document).intersects(visible)
        }
    }
}
