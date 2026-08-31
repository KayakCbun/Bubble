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
        print("PASS: multiline transcript host fitting height is \(height)")
    }
}
