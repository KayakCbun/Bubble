import AppKit
import SwiftUI

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("agentic UI layout check failed: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum AgenticUILayoutCheck {
    static func main() {
        _ = NSApplication.shared
        let raw: [String: Any] = [
            "summary": "Tuesday has the highest request volume.",
            "spec": [
                "root": "card",
                "elements": [
                    "card": [
                        "type": "Card",
                        "props": ["title": "Request volume"],
                        "children": ["chart"],
                    ],
                    "chart": [
                        "type": "BarChart",
                        "props": [
                            "title": "Requests by day",
                            "unit": "requests",
                            "points": [
                                ["label": "Monday", "value": 12],
                                ["label": "Tuesday", "value": 19],
                                ["label": "Wednesday", "value": 15],
                            ],
                        ],
                        "children": [],
                    ],
                ],
            ],
        ]
        guard let request = AgenticUIRequest.decodeAndValidate(raw) else {
            fputs("agentic UI layout check failed: fixture did not validate\n", stderr)
            exit(1)
        }

        let host = NSHostingView(rootView: AgenticUIView(request: request).frame(width: 620))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        require(size.width >= 600, "the native visualization uses the transcript width")
        require(size.height >= 240 && size.height < 500, "the native chart reports a bounded intrinsic height")
        require(size.width.isFinite && size.height.isFinite, "the native chart layout is finite")

        print("PASS: SwiftUI and Swift Charts produce a bounded native transcript row")
    }
}
