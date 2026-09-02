import AppKit
import SwiftUI

/// Flushed Record notes: the transcript keeps nested wheel ownership, SwiftUI's
/// system indicator stays hidden, and the visible knob is a true stadium.
struct RecordNotesBodyScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var geometry = RecordNotesScrollGeometry()

    var body: some View {
        ScrollView {
            content
                .background(RecordNotesScrollChrome())
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: RecordNotesScrollGeometry.self) { geo in
            RecordNotesScrollGeometry(
                offset: geo.visibleRect.minY,
                contentHeight: geo.contentSize.height,
                viewportHeight: geo.containerSize.height
            )
        } action: { _, new in
            geometry = new
        }
        .overlay(alignment: .topTrailing) {
            if geometry.showsKnob {
                Capsule(style: .circular)
                    .fill(Color.primary.opacity(0.28))
                    .frame(
                        width: RecordCardLayoutPolicy.scrollerKnobWidth,
                        height: geometry.knobHeight
                    )
                    .offset(y: geometry.knobOffset)
                    .padding(.trailing, RecordCardLayoutPolicy.scrollerTrailingInset)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct RecordNotesScrollGeometry: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0

    var showsKnob: Bool { knobHeight > 0 }

    var knobHeight: CGFloat {
        RecordCardLayoutPolicy.scrollerKnobHeight(
            contentHeight: contentHeight,
            viewportHeight: viewportHeight
        )
    }

    var knobOffset: CGFloat {
        RecordCardLayoutPolicy.scrollerKnobOffset(
            contentOffset: offset,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            knobHeight: knobHeight
        )
    }
}

/// Marks the nested `NSScrollView` so the transcript wheel monitor defers to it,
/// and hides the AppKit scroller that would otherwise cover the stadium knob.
struct RecordNotesScrollChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> RecordNotesScrollChromeView {
        RecordNotesScrollChromeView()
    }

    func updateNSView(_ nsView: RecordNotesScrollChromeView, context: Context) {
        nsView.apply()
    }
}

final class RecordNotesScrollChromeView: NSView {
    override var intrinsicContentSize: NSSize { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        apply()
    }

    override func layout() {
        super.layout()
        apply()
    }

    func apply() {
        guard let scroll = targetScrollView() else { return }
        scroll.identifier = NSUserInterfaceItemIdentifier(
            TranscriptNestedVerticalScrollPolicy.recordNotesIdentifier
        )
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
    }

    private func targetScrollView() -> NSScrollView? {
        var view: NSView? = superview
        while let current = view {
            if current is AppKitTranscriptScrollView { return nil }
            if let scroll = current as? NSScrollView { return scroll }
            view = current.superview
        }
        return nil
    }
}
