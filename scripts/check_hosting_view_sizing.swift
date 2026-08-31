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
        print("PASS: multiline transcript host fitting height is \(height)")
        print("PASS: block transcript host unconstrained height is \(unconstrainedHeight)")
    }
}
