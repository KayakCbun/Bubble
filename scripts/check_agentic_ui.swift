import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("agentic UI check failed: \(message)\n", stderr)
        exit(1)
    }
}

private func request(
    component: String = "BarChart",
    points: [[String: Any]] = [
        ["label": "Mon", "value": 12],
        ["label": "Tue", "value": 19],
        ["label": "Wed", "value": 15],
    ],
    rootChildren: [String] = ["chart"]
) -> [String: Any] {
    [
        "summary": "Requests increased from Monday to Tuesday, then eased on Wednesday.",
        "spec": [
            "root": "card",
            "elements": [
                "card": [
                    "type": "Card",
                    "props": ["title": "Requests by day"],
                    "children": rootChildren,
                ],
                "chart": [
                    "type": component,
                    "props": [
                        "title": "Requests",
                        "unit": "requests",
                        "points": points,
                    ],
                    "children": [],
                ],
            ],
        ],
    ]
}

@main
private enum AgenticUICheck {
    static func main() {
        let valid = AgenticUIRequest.decodeAndValidate(request())
        require(valid != nil, "a valid json-render-compatible chart spec is accepted")
        require(valid?.spec.root == "card", "the flat spec root is preserved")
        require(valid?.spec.elements["chart"]?.type == .barChart, "catalog component names decode to native types")
        require(valid?.spec.chartPoints(for: "chart").map(\.value) == [12, 19, 15], "numeric chart points stay ordered")

        require(
            AgenticUIRequest.decodeAndValidate(request(component: "WebView")) == nil,
            "components outside the native catalog are rejected"
        )
        var unknownProps = request()
        var unknownSpec = unknownProps["spec"] as! [String: Any]
        var unknownElements = unknownSpec["elements"] as! [String: Any]
        var unknownChart = unknownElements["chart"] as! [String: Any]
        var unknownChartProps = unknownChart["props"] as! [String: Any]
        unknownChartProps["javascript"] = "alert(1)"
        unknownChart["props"] = unknownChartProps
        unknownElements["chart"] = unknownChart
        unknownSpec["elements"] = unknownElements
        unknownProps["spec"] = unknownSpec
        require(
            AgenticUIRequest.decodeAndValidate(unknownProps) == nil,
            "unknown props cannot smuggle executable renderer behavior"
        )
        require(
            AgenticUIRequest.decodeAndValidate(request(rootChildren: ["card"])) == nil,
            "cycles are rejected before rendering"
        )

        let tooMany = (0...AgenticUILimits.maxChartPoints).map {
            ["label": "P\($0)", "value": $0] as [String: Any]
        }
        require(
            AgenticUIRequest.decodeAndValidate(request(points: tooMany)) == nil,
            "chart point limits are enforced"
        )
        require(
            AgenticUIRequest.decodeAndValidate(request(
                component: "DonutChart",
                points: [["label": "invalid", "value": -1]]
            )) == nil,
            "part-to-whole charts reject negative values"
        )

        let tableRequest: [String: Any] = [
            "summary": "Latency is highest in search.",
            "spec": [
                "root": "table",
                "elements": [
                    "table": [
                        "type": "Table",
                        "props": [
                            "title": "Service latency",
                            "columns": [
                                ["key": "service", "label": "Service"],
                                ["key": "p95", "label": "P95"],
                            ],
                            "rows": [
                                ["service": "search", "p95": 220],
                                ["service": "chat", "p95": 84],
                            ],
                        ],
                        "children": [],
                    ],
                ],
            ],
        ]
        let table = AgenticUIRequest.decodeAndValidate(tableRequest)
        require(table?.spec.tableColumns(for: "table").map(\.key) == ["service", "p95"], "typed tables preserve column order")
        require(table?.spec.tableRows(for: "table").count == 2, "typed tables preserve scalar rows")

        let data = try! JSONEncoder().encode(valid)
        let restored = try! JSONDecoder().decode(AgenticUIRequest.self, from: data)
        require(restored == valid, "validated UI requests persist without losing their spec")
        require(
            AgenticUITransportPolicy.isRenderToolUpdate(["title": "Native Visualization", "kind": "other"]),
            "the native render tool is hidden from the transcript transport"
        )
        require(
            !AgenticUITransportPolicy.isRenderToolUpdate(["title": "Read file", "kind": "read"]),
            "ordinary tool calls remain visible"
        )

        let custom: [String: Any] = [
            "type": "custom",
            "id": "native-ui",
            "parentId": NSNull(),
            "timestamp": "2026-09-03T10:00:00Z",
            "customType": "bubble_agentic_ui",
            "data": request(),
        ]
        let hiddenToolResult: [String: Any] = [
            "type": "message",
            "id": "render-result",
            "parentId": "native-ui",
            "message": [
                "role": "toolResult",
                "toolName": "bubble_render",
                "toolCallId": "render-1",
                "content": [["type": "text", "text": "Rendered natively in Bubble"]],
            ],
        ]
        let jsonl = [custom, hiddenToolResult].map { entry -> String in
            let data = try! JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            return String(data: data, encoding: .utf8)!
        }.joined(separator: "\n")
        let transcript = ConversationTreeSnapshot(jsonl: jsonl)?.transcript
        require(transcript?.count == 1, "replay restores the UI without a bubble_render tool row")
        require(transcript?.first?.agenticUI == valid, "the authoritative session entry restores the validated UI")
        require(transcript?.first?.branchable == false, "a generated UI block is not an editable assistant branch")

        print("PASS: native Agentic UI protocol and catalog validation")
    }
}
