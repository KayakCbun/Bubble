import AppKit
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
    private var eventMonitor: Any?
    private var userEventDeadline: TimeInterval = 0
    private var visibleAnchor: (id: String, offset: CGFloat)?
    private var correctingAnchor = false
    private let diagnosticsEnabled = ProcessInfo.processInfo.environment["BUBBLE_SCROLL_DIAGNOSTICS"] == "1"
    private var diagnosedUserScroll = false
    private var diagnosedAnchorRestore = false

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
        DispatchQueue.main.async { [weak self] in
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
            self.eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.scrollWheel, .leftMouseDragged, .keyDown]
            ) { [weak self] event in
                self?.recordUserEvent(event)
                return event
            }
            self.reportPosition()
            self.captureVisibleAnchor()
            if self.diagnosticsEnabled {
                OverlayLog.write("transcript scroll observer attached")
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
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        observedScrollView = nil
        observedDocument = nil
        visibleAnchor = nil
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
            captureVisibleAnchor()
        }
    }

    private func documentFrameChanged() {
        guard maintainsVisibleContent, visibleAnchor != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.restoreVisibleAnchor() }
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
        guard let anchor = visibleRowAnchors(in: document)
            .filter({ $0.frame.maxY >= visible.minY && $0.frame.minY <= visible.maxY })
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
              let anchor = visibleRowAnchors(in: document).first(where: { $0.id == visibleAnchor.id }) else {
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

    private func visibleRowAnchors(in document: NSView) -> [(id: String, frame: CGRect, position: CGFloat)] {
        descendantAnchors(in: document).map { anchor in
            let frame = anchor.convert(anchor.bounds, to: document)
            return (anchor.id, frame, document.isFlipped ? frame.minY : frame.maxY)
        }
    }

    private func descendantAnchors(in root: NSView) -> [TranscriptRowAnchorView] {
        var result: [TranscriptRowAnchorView] = []
        var pending = root.subviews
        while let view = pending.popLast() {
            if let anchor = view as? TranscriptRowAnchorView {
                result.append(anchor)
            } else {
                pending.append(contentsOf: view.subviews)
            }
        }
        return result
    }
}
