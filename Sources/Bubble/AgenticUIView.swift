import Charts
import SwiftUI

struct AgenticUIView: View {
    let request: AgenticUIRequest
    @State private var filterSelection: AgenticUIFilterSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let filterSelection {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    Text("Filtered: \(filterSelection.label)")
                        .lineLimit(1)
                    Button {
                        self.filterSelection = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Clear chart filter")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(OverlaySurface.cardFill))
                .accessibilityElement(children: .combine)
            }
            AgenticUIElementView(
                spec: request.spec,
                elementID: request.spec.root,
                depth: 1,
                filterSelection: $filterSelection
            )
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(request.summary)
    }
}

private struct AgenticUIElementView: View {
    let spec: AgenticUISpec
    let elementID: String
    let depth: Int
    @Binding var filterSelection: AgenticUIFilterSelection?

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
        case .areaChart:
            chartFrame(element) {
                areaChart(element)
            }
        case .donutChart:
            chartFrame(element) {
                donutChart(element)
            }
        case .scatterChart:
            chartFrame(element) {
                scatterChart(element)
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
        let visibleRows = AgenticUIInteractionPolicy.filteredRows(
            rows,
            filterColumn: spec.tableFilterColumn(for: elementID),
            filterGroup: spec.filterGroup(for: elementID),
            selection: filterSelection
        )
        return VStack(alignment: .leading, spacing: 8) {
            if let title = element.props["title"]?.string, !title.isEmpty {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OverlaySurface.conversationInk)
            }
            ScrollView(.horizontal, showsIndicators: visibleRows.count > 6) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    GridRow {
                        ForEach(columns, id: \.key) { column in
                            Text(column.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(visibleRows.enumerated()), id: \.offset) { _, row in
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
        let availableLabels = points.map(\.label)
        let filterApplies = filterApplies(to: availableLabels)
        return Chart(points) { point in
            if let series = point.series {
                BarMark(
                    x: .value("Category", point.label),
                    y: .value(element.props["unit"]?.string ?? "Value", point.value)
                )
                .foregroundStyle(by: .value("Series", series))
                .position(by: .value("Series", series), axis: .horizontal)
                .cornerRadius(3)
                .opacity(pointOpacity(point.label, filterApplies: filterApplies))
            } else {
                BarMark(
                    x: .value("Category", point.label),
                    y: .value(element.props["unit"]?.string ?? "Value", point.value)
                )
                .cornerRadius(3)
                .opacity(pointOpacity(point.label, filterApplies: filterApplies))
            }
        }
        .chartLegend(series.isEmpty ? .hidden : .visible)
        .agenticCategorySelection(
            points: points,
            style: .magnitude,
            filterGroup: spec.filterGroup(for: elementID),
            filterSelection: $filterSelection
        )
        .accessibilityHint("Click a bar to filter linked charts and tables")
    }

    private func lineChart(_ element: AgenticUIElement) -> some View {
        let points = spec.chartPoints(for: elementID)
        let series = Set(points.compactMap(\.series))
        let availableLabels = points.map(\.label)
        let filterApplies = filterApplies(to: availableLabels)
        return Chart(points) { point in
            if let series = point.series {
                LineMark(
                    x: .value("Category", point.label),
                    y: .value(element.props["unit"]?.string ?? "Value", point.value),
                    series: .value("Series", series)
                )
                .foregroundStyle(by: .value("Series", series))
                .lineStyle(by: .value("Series", series))
                PointMark(
                    x: .value("Category", point.label),
                    y: .value(element.props["unit"]?.string ?? "Value", point.value)
                )
                .foregroundStyle(by: .value("Series", series))
                .symbol(by: .value("Series", series))
                .opacity(pointOpacity(point.label, filterApplies: filterApplies))
            } else {
                LineMark(
                    x: .value("Category", point.label),
                    y: .value(element.props["unit"]?.string ?? "Value", point.value)
                )
                PointMark(
                    x: .value("Category", point.label),
                    y: .value(element.props["unit"]?.string ?? "Value", point.value)
                )
                .opacity(pointOpacity(point.label, filterApplies: filterApplies))
            }
        }
        .chartLegend(series.isEmpty ? .hidden : .visible)
        .agenticCategorySelection(
            points: points,
            style: .point,
            filterGroup: spec.filterGroup(for: elementID),
            filterSelection: $filterSelection
        )
        .accessibilityHint("Click a point to filter linked charts and tables")
    }

    private func areaChart(_ element: AgenticUIElement) -> some View {
        let points = spec.chartPoints(for: elementID)
        let series = Set(points.compactMap(\.series))
        let availableLabels = points.map(\.label)
        let filterApplies = filterApplies(to: availableLabels)
        return Chart(points) { point in
            if let series = point.series {
                AreaMark(
                    x: .value("Category", point.label),
                    y: .value(element.props["unit"]?.string ?? "Value", point.value),
                    series: .value("Series", series)
                )
                .foregroundStyle(by: .value("Series", series))
                .opacity(pointOpacity(point.label, filterApplies: filterApplies) * 0.35)
                LineMark(
                    x: .value("Category", point.label),
                    y: .value(element.props["unit"]?.string ?? "Value", point.value),
                    series: .value("Series", series)
                )
                .foregroundStyle(by: .value("Series", series))
                PointMark(
                    x: .value("Category", point.label),
                    y: .value(element.props["unit"]?.string ?? "Value", point.value)
                )
                .foregroundStyle(by: .value("Series", series))
                .opacity(pointOpacity(point.label, filterApplies: filterApplies))
            } else {
                AreaMark(
                    x: .value("Category", point.label),
                    y: .value(element.props["unit"]?.string ?? "Value", point.value)
                )
                .foregroundStyle(Color.accentColor.opacity(0.3))
                .opacity(pointOpacity(point.label, filterApplies: filterApplies))
                LineMark(
                    x: .value("Category", point.label),
                    y: .value(element.props["unit"]?.string ?? "Value", point.value)
                )
                PointMark(
                    x: .value("Category", point.label),
                    y: .value(element.props["unit"]?.string ?? "Value", point.value)
                )
                .opacity(pointOpacity(point.label, filterApplies: filterApplies))
            }
        }
        .chartLegend(series.isEmpty ? .hidden : .visible)
        .agenticCategorySelection(
            points: points,
            style: .magnitude,
            filterGroup: spec.filterGroup(for: elementID),
            filterSelection: $filterSelection
        )
        .accessibilityHint("Click a point to filter linked charts and tables")
    }

    private func donutChart(_ element: AgenticUIElement) -> some View {
        let points = spec.chartPoints(for: elementID)
        let availableLabels = points.map(\.label)
        let filterApplies = filterApplies(to: availableLabels)
        return Chart(points) { point in
            SectorMark(
                angle: .value(element.props["unit"]?.string ?? "Value", point.value),
                innerRadius: .ratio(0.55),
                angularInset: 1.5
            )
            .foregroundStyle(by: .value("Category", point.label))
            .cornerRadius(3)
            .opacity(pointOpacity(point.label, filterApplies: filterApplies))
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
        .agenticDonutSelection(
            points: points,
            filterGroup: spec.filterGroup(for: elementID),
            filterSelection: $filterSelection
        )
        .accessibilityHint("Click a slice to filter linked charts and tables")
    }

    private func scatterChart(_ element: AgenticUIElement) -> some View {
        let points = spec.scatterPoints(for: elementID)
        let series = Set(points.compactMap(\.series))
        let availableLabels = points.map(\.label)
        let filterApplies = filterApplies(to: availableLabels)
        return Chart(points) { point in
            if let series = point.series {
                PointMark(
                    x: .value(element.props["xLabel"]?.string ?? "X", point.x),
                    y: .value(element.props["yLabel"]?.string ?? "Y", point.y)
                )
                .foregroundStyle(by: .value("Series", series))
                .symbol(by: .value("Series", series))
                .symbolSize(pointOpacity(point.label, filterApplies: filterApplies) == 1 ? 80 : 35)
                .opacity(pointOpacity(point.label, filterApplies: filterApplies))
            } else {
                PointMark(
                    x: .value(element.props["xLabel"]?.string ?? "X", point.x),
                    y: .value(element.props["yLabel"]?.string ?? "Y", point.y)
                )
                .symbolSize(pointOpacity(point.label, filterApplies: filterApplies) == 1 ? 80 : 35)
                .opacity(pointOpacity(point.label, filterApplies: filterApplies))
            }
        }
        .chartLegend(series.isEmpty ? .hidden : .visible)
        .chartXAxisLabel(element.props["xLabel"]?.string ?? "X")
        .chartYAxisLabel(element.props["yLabel"]?.string ?? "Y")
        .agenticScatterSelection(
            points: points,
            filterGroup: spec.filterGroup(for: elementID),
            filterSelection: $filterSelection
        )
        .accessibilityHint("Click a point to filter linked charts and tables")
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
            AgenticUIElementView(
                spec: spec,
                elementID: childID,
                depth: depth + 1,
                filterSelection: $filterSelection
            )
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

    private func filterApplies(to availableLabels: [String]) -> Bool {
        let filterGroup = spec.filterGroup(for: elementID)
        guard let filterSelection,
              filterSelection.group == filterGroup else { return false }
        return availableLabels.contains {
            AgenticUIInteractionPolicy.isSelected(
                $0,
                filterGroup: filterGroup,
                selection: filterSelection
            )
        }
    }

    private func pointOpacity(_ label: String, filterApplies: Bool) -> Double {
        guard filterApplies else { return 1 }
        let filterGroup = spec.filterGroup(for: elementID)
        return AgenticUIInteractionPolicy.isSelected(
            label,
            filterGroup: filterGroup,
            selection: filterSelection
        ) ? 1 : 0.22
    }
}

private enum AgenticUICategoryHitStyle {
    case magnitude
    case point
}

private struct AgenticUICategorySelectionModifier: ViewModifier {
    let points: [AgenticUIChartPoint]
    let style: AgenticUICategoryHitStyle
    let filterGroup: String
    @Binding var filterSelection: AgenticUIFilterSelection?

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { event in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let frame = geometry[plotFrame]
                        guard frame.contains(event.location) else { return }
                        let local = CGPoint(x: event.location.x - frame.minX, y: event.location.y - frame.minY)
                        let candidates = points.compactMap({ point -> AgenticUIHitCandidate? in
                            guard let x = proxy.position(forX: point.label),
                                  let y = proxy.position(forY: point.value) else { return nil }
                            return AgenticUIHitCandidate(label: point.label, x: Double(x), y: Double(y))
                        })
                        let label: String?
                        switch style {
                        case .point:
                            label = AgenticUIInteractionPolicy.nearestPointLabel(
                                candidates: candidates,
                                tapX: Double(local.x),
                                tapY: Double(local.y),
                                maximumDistance: 36
                            )
                        case .magnitude:
                            guard let baselineY = proxy.position(forY: 0) else { return }
                            label = AgenticUIInteractionPolicy.magnitudeMarkLabel(
                                candidates: candidates,
                                baselineY: Double(baselineY),
                                tapX: Double(local.x),
                                tapY: Double(local.y),
                                maximumXDistance: maximumCategoryDistance(candidates)
                            )
                        }
                        guard let label else { return }
                        filterSelection = AgenticUIInteractionPolicy.toggledSelection(
                            current: filterSelection,
                            candidate: AgenticUIFilterSelection(group: filterGroup, label: label)
                        )
                    })
            }
        }
    }

    private func maximumCategoryDistance(_ candidates: [AgenticUIHitCandidate]) -> Double {
        let positions = Array(Set(candidates.map(\.x))).sorted()
        let minimumGap = zip(positions, positions.dropFirst()).map { $1 - $0 }.min()
        return min(48, max(12, (minimumGap ?? 72) * 0.45))
    }
}

private struct AgenticUIScatterSelectionModifier: ViewModifier {
    let points: [AgenticUIScatterPoint]
    let filterGroup: String
    @Binding var filterSelection: AgenticUIFilterSelection?

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { event in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let frame = geometry[plotFrame]
                        guard frame.contains(event.location) else { return }
                        let local = CGPoint(x: event.location.x - frame.minX, y: event.location.y - frame.minY)
                        let candidates = points.compactMap({ point -> AgenticUIHitCandidate? in
                            guard let x = proxy.position(forX: point.x),
                                  let y = proxy.position(forY: point.y) else { return nil }
                            return AgenticUIHitCandidate(label: point.label, x: Double(x), y: Double(y))
                        })
                        guard let label = AgenticUIInteractionPolicy.nearestPointLabel(
                            candidates: candidates,
                            tapX: Double(local.x),
                            tapY: Double(local.y),
                            maximumDistance: 36
                        ) else { return }
                        filterSelection = AgenticUIInteractionPolicy.toggledSelection(
                            current: filterSelection,
                            candidate: AgenticUIFilterSelection(group: filterGroup, label: label)
                        )
                    })
            }
        }
    }
}

private struct AgenticUIDonutSelectionModifier: ViewModifier {
    let points: [AgenticUIChartPoint]
    let filterGroup: String
    @Binding var filterSelection: AgenticUIFilterSelection?

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { event in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let frame = geometry[plotFrame]
                        let center = CGPoint(x: frame.midX, y: frame.midY)
                        let deltaX = event.location.x - center.x
                        let deltaY = event.location.y - center.y
                        let radius = hypot(deltaX, deltaY)
                        let outerRadius = min(frame.width, frame.height) / 2
                        guard outerRadius > 0 else { return }
                        var angle = atan2(deltaX, -deltaY)
                        if angle < 0 { angle += 2 * .pi }
                        guard let label = AgenticUIInteractionPolicy.donutLabel(
                            points: points,
                            angleFraction: Double(angle / (2 * .pi)),
                            radiusRatio: Double(radius / outerRadius)
                        ) else { return }
                        filterSelection = AgenticUIInteractionPolicy.toggledSelection(
                            current: filterSelection,
                            candidate: AgenticUIFilterSelection(group: filterGroup, label: label)
                        )
                    })
            }
        }
    }
}

private extension View {
    func agenticCategorySelection(
        points: [AgenticUIChartPoint],
        style: AgenticUICategoryHitStyle,
        filterGroup: String,
        filterSelection: Binding<AgenticUIFilterSelection?>
    ) -> some View {
        modifier(AgenticUICategorySelectionModifier(
            points: points,
            style: style,
            filterGroup: filterGroup,
            filterSelection: filterSelection
        ))
    }

    func agenticScatterSelection(
        points: [AgenticUIScatterPoint],
        filterGroup: String,
        filterSelection: Binding<AgenticUIFilterSelection?>
    ) -> some View {
        modifier(AgenticUIScatterSelectionModifier(
            points: points,
            filterGroup: filterGroup,
            filterSelection: filterSelection
        ))
    }

    func agenticDonutSelection(
        points: [AgenticUIChartPoint],
        filterGroup: String,
        filterSelection: Binding<AgenticUIFilterSelection?>
    ) -> some View {
        modifier(AgenticUIDonutSelectionModifier(
            points: points,
            filterGroup: filterGroup,
            filterSelection: filterSelection
        ))
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
