import Charts
import SwiftUI

struct AgenticUIView: View {
    let request: AgenticUIRequest

    var body: some View {
        AgenticUIElementView(spec: request.spec, elementID: request.spec.root, depth: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(request.summary)
    }
}

private struct AgenticUIElementView: View {
    let spec: AgenticUISpec
    let elementID: String
    let depth: Int

    var body: some View {
        if let element = spec.elements[elementID] {
            elementBody(element)
        } else {
            AgenticUIFallbackView(text: "This visualization is unavailable.")
        }
    }

    @ViewBuilder
    private func elementBody(_ element: AgenticUIElement) -> some View {
        switch element.type {
        case .stack:
            stack(element)
        case .card:
            card(element)
        case .heading:
            heading(element)
        case .text:
            prose(element)
        case .metric:
            metric(element)
        case .table:
            table(element)
        case .barChart:
            chartFrame(element) {
                barChart(element)
            }
        case .lineChart:
            chartFrame(element) {
                lineChart(element)
            }
        case .donutChart:
            chartFrame(element) {
                donutChart(element)
            }
        }
    }

    @ViewBuilder
    private func stack(_ element: AgenticUIElement) -> some View {
        let spacing = CGFloat(element.props["spacing"]?.number ?? 10)
        if element.props["axis"]?.string == "horizontal" {
            HStack(alignment: .top, spacing: spacing) {
                children(element)
            }
        } else {
            VStack(alignment: horizontalAlignment(element), spacing: spacing) {
                children(element)
            }
        }
    }

    private func card(_ element: AgenticUIElement) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = element.props["title"]?.string, !title.isEmpty {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OverlaySurface.conversationInk)
            }
            if let subtitle = element.props["subtitle"]?.string, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            children(element)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OverlaySurface.cardFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(OverlaySurface.cardStroke, lineWidth: 1)
                }
        )
    }

    private func heading(_ element: AgenticUIElement) -> some View {
        let level = Int(element.props["level"]?.number ?? 2)
        let size: CGFloat = switch level {
        case 1: 17
        case 3: 14
        default: 15
        }
        return Text(element.props["text"]?.string ?? "")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(OverlaySurface.conversationInk)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func prose(_ element: AgenticUIElement) -> some View {
        let style = element.props["style"]?.string ?? "body"
        let size: CGFloat = style == "caption" ? 11 : 13
        return Text(element.props["text"]?.string ?? "")
            .font(.system(size: size))
            .foregroundStyle(style == "body" ? AnyShapeStyle(OverlaySurface.conversationInk) : AnyShapeStyle(.secondary))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ element: AgenticUIElement) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(element.props["label"]?.string ?? "")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(element.props["value"]?.displayText ?? "")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(OverlaySurface.conversationInk)
                if let trend = element.props["trend"]?.number {
                    Text(trendLabel(trend))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(trend >= 0 ? Color.green : Color.red)
                }
            }
            if let detail = element.props["detail"]?.string, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func table(_ element: AgenticUIElement) -> some View {
        let columns = spec.tableColumns(for: elementID)
        let rows = spec.tableRows(for: elementID)
        return VStack(alignment: .leading, spacing: 8) {
            if let title = element.props["title"]?.string, !title.isEmpty {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OverlaySurface.conversationInk)
            }
            ScrollView(.horizontal, showsIndicators: rows.count > 6) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    GridRow {
                        ForEach(columns, id: \.key) { column in
                            Text(column.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(columns, id: \.key) { column in
                                Text(row[column.key]?.displayText ?? "")
                                    .font(.system(size: 12))
                                    .foregroundStyle(OverlaySurface.conversationInk)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func barChart(_ element: AgenticUIElement) -> some View {
        let points = spec.chartPoints(for: elementID)
        let series = Set(points.compactMap(\.series))
        return Chart(points) { point in
            BarMark(
                x: .value("Category", point.label),
                y: .value(element.props["unit"]?.string ?? "Value", point.value)
            )
            .foregroundStyle(by: .value("Series", point.series ?? element.props["title"]?.string ?? "Value"))
            .cornerRadius(3)
        }
        .chartLegend(series.isEmpty ? .hidden : .visible)
    }

    private func lineChart(_ element: AgenticUIElement) -> some View {
        let points = spec.chartPoints(for: elementID)
        let series = Set(points.compactMap(\.series))
        return Chart(points) { point in
            LineMark(
                x: .value("Category", point.label),
                y: .value(element.props["unit"]?.string ?? "Value", point.value),
                series: .value("Series", point.series ?? "Value")
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(by: .value("Series", point.series ?? element.props["title"]?.string ?? "Value"))
            PointMark(
                x: .value("Category", point.label),
                y: .value(element.props["unit"]?.string ?? "Value", point.value)
            )
            .foregroundStyle(by: .value("Series", point.series ?? element.props["title"]?.string ?? "Value"))
        }
        .chartLegend(series.isEmpty ? .hidden : .visible)
    }

    private func donutChart(_ element: AgenticUIElement) -> some View {
        Chart(spec.chartPoints(for: elementID)) { point in
            SectorMark(
                angle: .value(element.props["unit"]?.string ?? "Value", point.value),
                innerRadius: .ratio(0.55),
                angularInset: 1.5
            )
            .foregroundStyle(by: .value("Category", point.label))
            .cornerRadius(3)
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
    }

    private func chartFrame<Content: View>(
        _ element: AgenticUIElement,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(element.props["title"]?.string ?? "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OverlaySurface.conversationInk)
            content()
                .frame(height: 220)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func children(_ element: AgenticUIElement) -> some View {
        ForEach(element.children, id: \.self) { childID in
            AgenticUIElementView(spec: spec, elementID: childID, depth: depth + 1)
        }
    }

    private func horizontalAlignment(_ element: AgenticUIElement) -> HorizontalAlignment {
        switch element.props["alignment"]?.string {
        case "center": .center
        case "trailing": .trailing
        default: .leading
        }
    }

    private func trendLabel(_ value: Double) -> String {
        let prefix = value > 0 ? "+" : ""
        return prefix + value.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }
}

private struct AgenticUIFallbackView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "chart.bar.xaxis")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(OverlaySurface.cardFill))
    }
}
