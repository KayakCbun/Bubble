import AppKit
import SwiftUI

@main
private enum HostingViewSizingCheck {
    static func main() {
        let text = Array(
            repeating: "这是一段用于检测多行消息高度的文本。",
            count: 40
        ).joined(separator: "\n")
        let hostingView = NSHostingView(
            rootView: AnyView(
                Text(text)
                    .frame(width: 520, alignment: .leading)
            )
        )
        hostingView.sizingOptions = TranscriptHostingSizingPolicy.options
        hostingView.frame = NSRect(x: 0, y: 0, width: 520, height: 1)
        hostingView.layoutSubtreeIfNeeded()
        let height = hostingView.fittingSize.height
        guard height.isFinite, height > 200 else {
            fputs("FAIL: multiline transcript host fitting height is \(height)\n", stderr)
            exit(1)
        }
        let blockHostingController = NSHostingController(
            rootView: AnyView(
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<32, id: \.self) { index in
                        Text("\(index + 1). 这是一段用于检测恢复消息宿主是否会压缩正文的文本。")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Image(systemName: "square.on.square")
                        Image(systemName: "arrow.triangle.branch")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            )
        )
        blockHostingController.sizingOptions = TranscriptHostingSizingPolicy.options
        let blockHostingView = blockHostingController.view
        blockHostingView.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        blockHostingView.layoutSubtreeIfNeeded()
        let unconstrainedHeight = TranscriptHostingSizingPolicy.contentHeight(
            of: blockHostingController,
            width: 520
        )
        guard unconstrainedHeight > 900 else {
            fputs("FAIL: block transcript host unconstrained height is \(unconstrainedHeight)\n", stderr)
            exit(1)
        }
        let disclosureController = NSHostingController(
            rootView: TranscriptHostingSizingPolicy.root(
                AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    Text("Thoughts")
                    HStack(alignment: .top, spacing: 10) {
                        Capsule().frame(width: 2)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            Text("Expanded reasoning content")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                )
            )
        )
        disclosureController.sizingOptions = TranscriptHostingSizingPolicy.options
        disclosureController.view.frame = NSRect(x: 0, y: 0, width: 520, height: 42)
        disclosureController.view.layoutSubtreeIfNeeded()
        let disclosureHeight = TranscriptHostingSizingPolicy.contentHeight(
            of: disclosureController,
            width: 520
        )
        guard disclosureHeight < 1_000 else {
            fputs("FAIL: expanded disclosure host height is \(disclosureHeight)\n", stderr)
            exit(1)
        }
        let toolOutput = Array(
            repeating: "tool output line with enough content to exercise wrapping",
            count: 140
        ).joined(separator: "\n")
        let toolController = NSHostingController(
            rootView: TranscriptHostingSizingPolicy.root(
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tool bash")
                    HStack(alignment: .top, spacing: 10) {
                        Capsule().frame(width: 2)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Output")
                            Text(toolOutput)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            )
        )
        toolController.sizingOptions = TranscriptHostingSizingPolicy.options
        toolController.view.frame = NSRect(x: 0, y: 0, width: 520, height: 42)
        toolController.view.layoutSubtreeIfNeeded()
        let toolHeight = TranscriptHostingSizingPolicy.contentHeight(
            of: toolController,
            width: 520
        )
        guard toolHeight > 2_000, toolHeight < 5_000 else {
            fputs("FAIL: expanded tool host height is \(toolHeight)\n", stderr)
            exit(1)
        }
        let rowContainer = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 42))
        toolController.view.frame = rowContainer.bounds
        toolController.view.autoresizingMask = TranscriptHostingSizingPolicy.autoresizingMask
        rowContainer.addSubview(toolController.view)
        rowContainer.setFrameSize(NSSize(width: 520, height: toolHeight))
        guard abs(toolController.view.frame.height - toolHeight) < 0.5 else {
            fputs(
                "FAIL: expanded tool surface stayed at collapsed height "
                    + "\(toolController.view.frame.height) instead of \(toolHeight)\n",
                stderr
            )
            exit(1)
        }
        print("PASS: multiline transcript host fitting height is \(height)")
        print("PASS: block transcript host unconstrained height is \(unconstrainedHeight)")
        print("PASS: expanded disclosure host height is \(disclosureHeight)")
        print("PASS: expanded tool host height is \(toolHeight)")
        print("PASS: expanded tool surface follows its AppKit row height")
    }
}
