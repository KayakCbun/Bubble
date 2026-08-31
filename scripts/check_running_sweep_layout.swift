import AppKit
import SwiftUI

private var failures: [String] = []

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}

/// Mirrors the transcript implementation that regressed: an animated
/// TimelineView is embedded directly in each virtualized SwiftUI row.
private struct TimelineRunningLabel: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0)) { context in
            let progress = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.45) / 1.45
            Text("running")
                .foregroundStyle(
                    LinearGradient(
                        colors: [.secondary.opacity(0.34), .primary.opacity(0.84), .secondary.opacity(0.34)],
                        startPoint: UnitPoint(x: progress - 0.24, y: 0.5),
                        endPoint: UnitPoint(x: progress + 0.24, y: 0.5)
                    )
                )
        }
        .font(.system(size: 11, weight: .medium))
    }
}

private struct TranscriptPair: View {
    let showRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tool grep")
                Spacer()
                if showRunning { TimelineRunningLabel() }
            }
            Text("The next assistant message must remain fully visible.")
            if showRunning { TimelineRunningLabel() }
        }
        .frame(width: 520, alignment: .leading)
    }
}

private final class InvalidationCountingHost<Content: View>: NSHostingView<Content> {
    private(set) var fullRowInvalidations = 0

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        if bounds.width > 0,
           invalidRect.width >= bounds.width - 1,
           invalidRect.height >= bounds.height - 1 {
            fullRowInvalidations += 1
        }
        super.setNeedsDisplay(invalidRect)
    }
}

@main
private enum RunningSweepLayoutCheck {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let host = InvalidationCountingHost(rootView: TranscriptPair(showRunning: false))
        host.sizingOptions = [.intrinsicContentSize]
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 1)
        host.layoutSubtreeIfNeeded()
        let oldHeight = host.fittingSize.height
        host.frame.size.height = oldHeight

        // This is the virtualized transcript transition: existing mounted
        // rows are reconfigured in place when tool/assistant state becomes
        // running, then sampled synchronously before SwiftUI's next turn.
        host.rootView = TranscriptPair(showRunning: true)
        host.layoutSubtreeIfNeeded()
        let firstHeight = host.fittingSize.height

        let invalidationsBeforeAnimation = host.fullRowInvalidations

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        host.layoutSubtreeIfNeeded()
        let settledHeight = host.fittingSize.height

        expect(firstHeight > 1, "the first fitting pass returns a usable transcript height")
        expect(
            abs(firstHeight - settledHeight) <= 0.5,
            "animated running labels keep a stable intrinsic height (first \(firstHeight), settled \(settledHeight))"
        )
        expect(
            host.fullRowInvalidations == invalidationsBeforeAnimation,
            "running animation does not invalidate the whole virtualized transcript host"
        )

        // The transcript row itself is one layer-masked NSHostingView. A
        // SwiftUI TimelineView inside it repaints at display cadence and can
        // transiently blank a horizontal band across the tool row and the
        // following assistant row. Keep the animation in a fixed-intrinsic
        // AppKit subview so only the tiny label layer is animated.
        let overlaySource = try! String(
            contentsOfFile: "Sources/Bubble/OverlayView.swift",
            encoding: .utf8
        )
        if let labelStart = overlaySource.range(of: "struct RunningSweepLabel"),
           let labelEnd = overlaySource.range(
               of: "private struct LayerPulsingCaret",
               range: labelStart.upperBound..<overlaySource.endIndex
           ) {
            let implementation = overlaySource[labelStart.lowerBound..<labelEnd.lowerBound]
            expect(
                !implementation.contains("TimelineView"),
                "running sweep avoids a display-linked TimelineView inside virtualized transcript rows"
            )
            if let alphaStart = implementation.range(
                of: "secondaryLabelColor.withAlphaComponent("
            ) {
                let suffix = implementation[alphaStart.upperBound...]
                if let alphaEnd = suffix.firstIndex(of: ")"),
                   let alpha = Double(suffix[..<alphaEnd]) {
                    expect(
                        alpha >= 0.56,
                        "running sweep keeps the whole word legible between highlight passes (base alpha \(alpha))"
                    )
                } else {
                    failures.append("running sweep base alpha remains measurable")
                }
            } else {
                failures.append("running sweep base color remains discoverable")
            }
        } else {
            failures.append("running sweep implementation remains discoverable")
        }
        if let chunkStart = overlaySource.range(of: "private func assistantChunkRow"),
           let chunkEnd = overlaySource.range(
               of: "private func assistantImageGrid",
               range: chunkStart.upperBound..<overlaySource.endIndex
           ) {
            let implementation = overlaySource[chunkStart.lowerBound..<chunkEnd.lowerBound]
            expect(
                !implementation.contains(".firstTextBaseline"),
                "completed virtual chunks do not shift multi-block Markdown against a baseline container"
            )
        } else {
            failures.append("assistant chunk implementation remains discoverable")
        }

        if failures.isEmpty {
            print("PASS: running sweep layout")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(1)
        }
    }
}
