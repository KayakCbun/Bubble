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
            AgenticUIRequest.decodeAndValidate(request(component: "AreaChart"))?.spec.elements["chart"]?.type == .areaChart,
            "area charts are accepted as a native time-series component"
        )

        let scatterRequest: [String: Any] = [
            "summary": "Higher deployment frequency is associated with lower lead time.",
            "spec": [
                "root": "scatter",
                "elements": [
                    "scatter": [
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
        let scatter = AgenticUIRequest.decodeAndValidate(scatterRequest)
        require(scatter?.spec.elements["scatter"]?.type == .scatterChart, "scatter charts are accepted as a native correlation component")
        require(scatter?.spec.scatterPoints(for: "scatter").map(\.x) == [12, 7], "scatter coordinates remain numeric and ordered")

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
        require(
            AgenticUIRequest.decodeAndValidate(request(
                component: "DonutChart",
                points: [
                    ["label": "same", "value": 1, "series": "one"],
                    ["label": "same", "value": 2, "series": "two"],
                ]
            )) == nil,
            "donut slices reject series metadata that the native renderer cannot distinguish"
        )

        let sharedSubtreeTooDeep: [String: Any] = [
            "summary": "Shared subtrees still obey the depth limit.",
            "spec": [
                "root": "root",
                "elements": [
                    "root": ["type": "Stack", "props": [:], "children": ["shared", "a"]],
                    "a": ["type": "Stack", "props": [:], "children": ["b"]],
                    "b": ["type": "Stack", "props": [:], "children": ["c"]],
                    "c": ["type": "Stack", "props": [:], "children": ["d"]],
                    "d": ["type": "Stack", "props": [:], "children": ["e"]],
                    "e": ["type": "Stack", "props": [:], "children": ["shared"]],
                    "shared": ["type": "Stack", "props": [:], "children": ["tail1"]],
                    "tail1": ["type": "Stack", "props": [:], "children": ["tail2"]],
                    "tail2": ["type": "Text", "props": ["text": "end"], "children": []],
                ],
            ],
        ]
        require(
            AgenticUIRequest.decodeAndValidate(sharedSubtreeTooDeep) == nil,
            "a shared subtree cannot bypass the maximum render depth"
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
                            "filterColumn": "service",
                            "filterGroup": "services",
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
        require(table?.spec.tableFilterColumn(for: "table") == "service", "tables expose their chart-linking filter column")
        require(table?.spec.filterGroup(for: "table") == "services", "linked components expose an explicit filter group")

        var invalidGroupTable = tableRequest
        var invalidGroupSpec = invalidGroupTable["spec"] as! [String: Any]
        var invalidGroupElements = invalidGroupSpec["elements"] as! [String: Any]
        var invalidGroupElement = invalidGroupElements["table"] as! [String: Any]
        var invalidGroupProps = invalidGroupElement["props"] as! [String: Any]
        invalidGroupProps["filterGroup"] = "   "
        invalidGroupElement["props"] = invalidGroupProps
        invalidGroupElements["table"] = invalidGroupElement
        invalidGroupSpec["elements"] = invalidGroupElements
        invalidGroupTable["spec"] = invalidGroupSpec
        require(
            AgenticUIRequest.decodeAndValidate(invalidGroupTable) == nil,
            "blank filter groups are rejected instead of linking components ambiguously"
        )

        let candidate = AgenticUIFilterSelection(group: "services", label: "search")
        let selected = AgenticUIInteractionPolicy.toggledSelection(current: nil, candidate: candidate)
        require(selected == candidate, "clicking a chart value selects its grouped label")
        require(
            AgenticUIInteractionPolicy.toggledSelection(current: selected, candidate: candidate) == nil,
            "clicking the selected value again clears the filter"
        )
        let filteredRows = AgenticUIInteractionPolicy.filteredRows(
            table!.spec.tableRows(for: "table"),
            filterColumn: table!.spec.tableFilterColumn(for: "table"),
            filterGroup: table!.spec.filterGroup(for: "table"),
            selection: selected
        )
        require(filteredRows.count == 1 && filteredRows[0]["service"]?.displayText == "search", "a linked table filters to the selected chart label")
        require(
            AgenticUIInteractionPolicy.filteredRows(
                table!.spec.tableRows(for: "table"),
                filterColumn: table!.spec.tableFilterColumn(for: "table"),
                filterGroup: table!.spec.filterGroup(for: "table"),
                selection: AgenticUIFilterSelection(group: "unrelated", label: "search")
            ).count == 2,
            "the same label from an unrelated chart group does not filter the table"
        )
        require(
            AgenticUIInteractionPolicy.nearestPointLabel(
                candidates: [
                    AgenticUIHitCandidate(label: "Mon", x: 20, y: 40),
                    AgenticUIHitCandidate(label: "Tue", x: 80, y: 70),
                    AgenticUIHitCandidate(label: "Wed", x: 140, y: 50),
                ],
                tapX: 73,
                tapY: 74,
                maximumDistance: 36
            ) == "Tue",
            "a line-chart click resolves to the nearest visible point"
        )
        require(
            AgenticUIInteractionPolicy.nearestPointLabel(
                candidates: [
                    AgenticUIHitCandidate(label: "Search", x: 30, y: 40),
                    AgenticUIHitCandidate(label: "Chat", x: 130, y: 160),
                ],
                tapX: 35,
                tapY: 43,
                maximumDistance: 36
            ) == "Search",
            "a scatter click resolves to a nearby point"
        )
        require(
            AgenticUIInteractionPolicy.nearestPointLabel(
                candidates: [AgenticUIHitCandidate(label: "Search", x: 30, y: 40)],
                tapX: 100,
                tapY: 100,
                maximumDistance: 36
            ) == nil,
            "a scatter click in empty space does not create a misleading filter"
        )
        require(
            AgenticUIInteractionPolicy.magnitudeMarkLabel(
                candidates: [
                    AgenticUIHitCandidate(label: "Mon", x: 20, y: 80),
                    AgenticUIHitCandidate(label: "Tue", x: 80, y: 30),
                ],
                baselineY: 180,
                tapX: 82,
                tapY: 120,
                maximumXDistance: 24
            ) == "Tue",
            "a bar or area click inside a visible magnitude mark selects its category"
        )
        require(
            AgenticUIInteractionPolicy.magnitudeMarkLabel(
                candidates: [AgenticUIHitCandidate(label: "Tue", x: 80, y: 30)],
                baselineY: 180,
                tapX: 82,
                tapY: 12,
                maximumXDistance: 24
            ) == nil,
            "a categorical chart click above the rendered mark does not select"
        )
        require(
            AgenticUIInteractionPolicy.donutLabel(
                points: [
                    AgenticUIChartPoint(label: "A", value: 25, series: nil),
                    AgenticUIChartPoint(label: "B", value: 75, series: nil),
                ],
                angleFraction: 0.5,
                radiusRatio: 0.8
            ) == "B",
            "a donut click maps its angle to the corresponding slice"
        )
        require(
            AgenticUIInteractionPolicy.donutLabel(
                points: [AgenticUIChartPoint(label: "A", value: 1, series: nil)],
                angleFraction: 0,
                radiusRatio: 0.2
            ) == nil,
            "a click in the donut hole does not select a slice"
        )
        require(
            AgenticUIInteractionPolicy.donutLabel(
                points: [
                    AgenticUIChartPoint(label: "Invisible", value: 0, series: nil),
                    AgenticUIChartPoint(label: "Visible", value: 10, series: nil),
                ],
                angleFraction: 0,
                radiusRatio: 0.8
            ) == "Visible",
            "a zero-value donut slice cannot be selected even at an angular boundary"
        )

        let data = try! JSONEncoder().encode(valid)
        let restored = try! JSONDecoder().decode(AgenticUIRequest.self, from: data)
        require(restored == valid, "validated UI requests persist without losing their spec")

        var identifiedRequest = request()
        identifiedRequest["blockID"] = "tool-call-42"
        let identified = AgenticUIRequest.decodeAndValidate(identifiedRequest)
        require(identified?.blockID == "tool-call-42", "the stable tool-call ID survives host validation")
        require(
            AgenticUIBlockIdentity.matches(identified!, identified),
            "a retry after a lost response resolves to the existing native block"
        )
        var secondRequest = request()
        secondRequest["blockID"] = "tool-call-43"
        require(
            !AgenticUIBlockIdentity.matches(
                AgenticUIRequest.decodeAndValidate(secondRequest)!,
                identified
            ),
            "a distinct tool call is not suppressed as a retry"
        )
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
            "data": identifiedRequest,
        ]
        let duplicateCustom: [String: Any] = [
            "type": "custom",
            "id": "native-ui-retry",
            "parentId": "native-ui",
            "timestamp": "2026-09-03T10:00:01Z",
            "customType": "bubble_agentic_ui",
            "data": identifiedRequest,
        ]
        let hiddenToolResult: [String: Any] = [
            "type": "message",
            "id": "render-result",
            "parentId": "native-ui-retry",
            "message": [
                "role": "toolResult",
                "toolName": "bubble_render",
                "toolCallId": "render-1",
                "content": [["type": "text", "text": "Rendered natively in Bubble"]],
            ],
        ]
        let jsonl = [custom, duplicateCustom, hiddenToolResult].map { entry -> String in
            let data = try! JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            return String(data: data, encoding: .utf8)!
        }.joined(separator: "\n")
        let transcript = ConversationTreeSnapshot(jsonl: jsonl)?.transcript
        require(transcript?.count == 1, "replay deduplicates a retried UI entry and hides the bubble_render tool row")
        require(transcript?.first?.agenticUI == identified, "the authoritative session entry restores the validated UI and block identity")
        require(transcript?.first?.branchable == false, "a generated UI block is not an editable assistant branch")

        print("PASS: native Agentic UI protocol and catalog validation")
    }
}
