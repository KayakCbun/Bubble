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

        let areaRaw: [String: Any] = [
            "summary": "Weekly traffic grew steadily.",
            "spec": [
                "root": "chart",
                "elements": [
                    "chart": [
                        "type": "AreaChart",
                        "props": [
                            "title": "Weekly traffic",
                            "unit": "requests",
                            "points": [
                                ["label": "W1", "value": 120],
                                ["label": "W2", "value": 180],
                                ["label": "W3", "value": 240],
                            ],
                        ],
                        "children": [],
                    ],
                ],
            ],
        ]
        let scatterRaw: [String: Any] = [
            "summary": "Deploy frequency and lead time are inversely related.",
            "spec": [
                "root": "chart",
                "elements": [
                    "chart": [
                        "type": "ScatterChart",
                        "props": [
                            "title": "Delivery performance",
                            "xLabel": "Deployments per week",
                            "yLabel": "Lead time (hours)",
                            "points": [
                                ["label": "Search", "x": 12, "y": 4.2],
                                ["label": "Chat", "x": 7, "y": 8.4],
                            ],
                        ],
                        "children": [],
                    ],
                ],
            ],
        ]
        for (name, fixture) in [("area", areaRaw), ("scatter", scatterRaw)] {
            guard let request = AgenticUIRequest.decodeAndValidate(fixture) else {
                fputs("agentic UI layout check failed: \(name) fixture did not validate\n", stderr)
                exit(1)
            }
            let host = NSHostingView(rootView: AgenticUIView(request: request).frame(width: 620))
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            require(size.height >= 220 && size.height < 400, "the native \(name) chart has a bounded intrinsic height")
            require(size.width.isFinite && size.height.isFinite, "the native \(name) chart layout is finite")
        }

        print("PASS: SwiftUI and Swift Charts produce a bounded native transcript row")
    }
}
