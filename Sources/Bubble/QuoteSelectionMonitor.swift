import AppKit
import Combine

final class QuoteSelectionMonitor: ObservableObject {
    static let shared = QuoteSelectionMonitor()

    struct Snapshot: Equatable {
        var text: String
        var selection: CGRect
    }

    @Published var snapshot: Snapshot?
    private var tokens: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var hostingSize: CGSize = .zero

    func start() {
        guard tokens.isEmpty else {
            refresh()
            return
        }
        let center = NotificationCenter.default
        tokens.append(
            center.addObserver(
                forName: NSTextView.didChangeSelectionNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
        )
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .leftMouseDragged]
        ) { [weak self] event in
            if event.type == .leftMouseUp {
                DispatchQueue.main.async { self?.refresh() }
            }
            return event
        }
        refresh()
    }

    func stop() {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens.removeAll()
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        setSnapshot(nil)
    }

    func dismiss() {
        setSnapshot(nil)
        clearTranscriptSelection()
    }

    func refresh() {
        let window = NSApp.windows.first(where: { $0 is OverlayPanel && $0.isVisible })
        guard let window, let content = window.contentView else {
            setSnapshot(nil)
            return
        }
        hostingSize = content.bounds.size
        if let responder = window.firstResponder as? NSTextView, responder.isEditable {
            setSnapshot(nil)
            return
        }
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        guard let source = selectedTranscriptView(in: content) else {
            setSnapshot(nil)
            return
        }
        let nsRange = source.selectedRange()
        guard nsRange.length > 0, nsRange.location != NSNotFound else {
            setSnapshot(nil)
            return
        }
        let raw = (source.string as NSString).substring(with: nsRange)
        guard let quoted = QuoteSelectionPolicy.quotedText(from: raw) else {
            setSnapshot(nil)
            return
        }
        guard QuoteSelectionPolicy.showsChip(mousePressed: pressed, quoted: quoted) else {
            setSnapshot(nil)
            return
        }
        var actual = nsRange
        let screenRect = source.firstRect(forCharacterRange: nsRange, actualRange: &actual)
        guard screenRect.width > 0 || screenRect.height > 0 else {
            setSnapshot(nil)
            return
        }
        let windowRect = window.convertFromScreen(screenRect)
        let local = content.convert(windowRect, from: nil)
        let swiftRect: CGRect
        if content.isFlipped {
            swiftRect = CGRect(
                x: local.minX,
                y: local.minY,
                width: max(local.width, 8),
                height: max(local.height, 12)
            )
        } else {
            swiftRect = CGRect(
                x: local.minX,
                y: content.bounds.height - local.maxY,
                width: max(local.width, 8),
                height: max(local.height, 12)
            )
        }
        setSnapshot(Snapshot(text: quoted, selection: swiftRect))
    }

    /// Typing in the composer fires selection notifications. Publishing the same
    /// nil snapshot retriggers the whole overlay, which re-parses file diffs.
    private func setSnapshot(_ next: Snapshot?) {
        guard snapshot != next else { return }
        snapshot = next
    }

    private func selectedTranscriptView(in root: NSView) -> NSTextView? {
        var views: [NSTextView] = []
        collectTextViews(from: root, into: &views)
        if let first = views.first(where: {
            QuoteSelectionPolicy.acceptsSource(isEditable: $0.isEditable, isSelectable: $0.isSelectable)
                && $0.selectedRange().length > 0
                && ($0.window?.firstResponder === $0 || $0.selectedRange().length > 0)
        }) {
            return first
        }
        return nil
    }

    private func collectTextViews(from view: NSView, into views: inout [NSTextView]) {
        if let textView = view as? NSTextView {
            views.append(textView)
        }
        for child in view.subviews {
            collectTextViews(from: child, into: &views)
        }
    }

    private func clearTranscriptSelection() {
        let window = NSApp.windows.first(where: { $0 is OverlayPanel && $0.isVisible })
        guard let content = window?.contentView else { return }
        var views: [NSTextView] = []
        collectTextViews(from: content, into: &views)
        for view in views where !view.isEditable {
            view.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }
}
