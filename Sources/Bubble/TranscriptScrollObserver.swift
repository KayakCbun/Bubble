import AppKit
import QuartzCore
import SwiftUI

struct TranscriptRowAnchor: NSViewRepresentable {
    var id: String

    func makeNSView(context: Context) -> TranscriptRowAnchorView {
        TranscriptRowAnchorView(id: id)
    }

    func updateNSView(_ view: TranscriptRowAnchorView, context: Context) {
        view.id = id
    }
}

final class TranscriptRowAnchorView: NSView {
    var id: String

    init(id: String) {
        self.id = id
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

private extension Notification.Name {
    static let transcriptRowAnchorChanged = Notification.Name("BubbleTranscriptRowAnchorChanged")
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
        view.maintainsVisibleContent = maintainsVisibleContent
        return view
    }

    func updateNSView(_ view: TranscriptScrollProbe, context: Context) {
        view.onChange = onChange
        view.maintainsVisibleContent = maintainsVisibleContent
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
    private var eventMonitor: Any?
    private var userEventDeadline: TimeInterval = 0
    private var visibleAnchor: (id: String, offset: CGFloat)?
    private var correctingAnchor = false
    private let diagnosticsMode = ProcessInfo.processInfo.environment["BUBBLE_SCROLL_DIAGNOSTICS"]
    private var diagnosedUserScroll = false
    private var diagnosedAnchorRestore = false
    private var rowAnchors: [ObjectIdentifier: WeakTranscriptRowAnchor] = [:]
    private var anchorIndex: [(id: String, frame: CGRect, position: CGFloat)] = []
    private var anchorCaptureQueued = false
    private var anchorRestoreQueued = false
    private var anchorIndexRebuildQueued = false
    private var diagnosticFramesRemaining = 0
    private var diagnosticDirection: CGFloat = -1
    private var diagnosticLastTick: TimeInterval?
    private var diagnosticFrameIntervals: [TimeInterval] = []
    private var diagnosticDisplayLink: CADisplayLink?

    private var diagnosticsEnabled: Bool { diagnosticsMode != nil }

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
            self.eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.scrollWheel, .leftMouseDragged, .keyDown]
            ) { [weak self] event in
                self?.recordUserEvent(event)
                return event
            }
            self.reportPosition()
            self.registerExistingAnchors(in: document)
            self.rebuildAnchorIndex()
            self.captureVisibleAnchor()
            if self.diagnosticsEnabled {
                OverlayLog.write("transcript scroll observer attached")
            }
            if self.diagnosticsMode == "drive" {
                self.startDiagnosticDrive()
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
        diagnosticDisplayLink?.invalidate()
        diagnosticDisplayLink = nil
    }

    private func recordUserEvent(_ event: NSEvent) {
        guard let scrollView = observedScrollView,
              event.window === scrollView.window else { return }
        if event.type == .keyDown {
            guard Self.navigationKeyCodes.contains(event.keyCode),
                  let responder = scrollView.window?.firstResponder as? NSView,
                  responder === scrollView || responder.isDescendant(of: scrollView) else { return }
        } else {
            let frameInWindow = scrollView.convert(scrollView.bounds, to: nil)
            guard frameInWindow.contains(event.locationInWindow) else { return }
        }
        userEventDeadline = ProcessInfo.processInfo.systemUptime + Self.userEventWindow
        if diagnosticsEnabled, !diagnosedUserScroll {
            diagnosedUserScroll = true
            OverlayLog.write("transcript physical scroll observed")
        }
        DispatchQueue.main.async { [weak self] in self?.reportPosition() }
    }

    private func boundsChanged() {
        reportPosition()
        if maintainsVisibleContent, !correctingAnchor {
            scheduleVisibleAnchorCapture()
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
        let userDriven = ProcessInfo.processInfo.systemUptime <= userEventDeadline
        onChange?(atEnd, userDriven)
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
            return (anchor.id, frame, document.isFlipped ? frame.minY : frame.maxY)
        }
        .sorted { $0.frame.minY < $1.frame.minY }
    }

    private func visibleAnchorCandidates(in visible: CGRect) -> ArraySlice<(id: String, frame: CGRect, position: CGFloat)> {
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
        scheduleAnchorIndexRebuild()
    }

    private func scheduleAnchorIndexRebuild() {
        guard !anchorIndexRebuildQueued else { return }
        anchorIndexRebuildQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) { [weak self] in
            guard let self else { return }
            self.anchorIndexRebuildQueued = false
            self.rebuildAnchorIndex()
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
        maintainsVisibleContent = true
        diagnosticFramesRemaining = 720
        diagnosticFrameIntervals.removeAll(keepingCapacity: true)
        diagnosticLastTick = nil
        let link = window.displayLink(target: self, selector: #selector(diagnosticTick(_:)))
        link.preferredFrameRateRange = OverlayMotion.frameRate
        link.add(to: .main, forMode: .common)
        diagnosticDisplayLink = link
    }

    @objc private func diagnosticTick(_ link: CADisplayLink) {
        guard diagnosticFramesRemaining > 0,
              let scrollView = observedScrollView,
              let document = observedDocument else {
            link.invalidate()
            diagnosticDisplayLink = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = diagnosticLastTick {
            diagnosticFrameIntervals.append(now - last)
        }
        diagnosticLastTick = now

        let visible = scrollView.contentView.bounds
        let minimumY = document.bounds.minY
        let maximumY = max(minimumY, document.bounds.maxY - visible.height)
        var nextY = visible.minY + diagnosticDirection * 180
        if nextY <= minimumY || nextY >= maximumY {
            diagnosticDirection *= -1
            nextY = min(maximumY, max(minimumY, visible.minY + diagnosticDirection * 180))
        }
        scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: nextY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        diagnosticFramesRemaining -= 1

        if diagnosticFramesRemaining == 0 {
            let sorted = diagnosticFrameIntervals.sorted()
            let p95Index = min(max(0, Int(Double(sorted.count) * 0.95)), max(0, sorted.count - 1))
            let p95 = sorted.isEmpty ? 0 : sorted[p95Index] * 1_000
            let maximum = (sorted.last ?? 0) * 1_000
            OverlayLog.write(
                String(
                    format: "transcript scroll benchmark frames=%d p95=%.2fms max=%.2fms anchors=%d",
                    diagnosticFrameIntervals.count,
                    p95,
                    maximum,
                    anchorIndex.count
                )
            )
            link.invalidate()
            diagnosticDisplayLink = nil
            return
        }
    }
}
