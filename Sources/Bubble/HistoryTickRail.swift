import SwiftUI

enum HistoryLimits {
    static let maxTitleChars = 32
    static let maxBodyChars = 80
    static let rawScanChars = 2000
    static let gutter: CGFloat = 22
}

struct HistoryTick: Identifiable, Equatable {
    var id: UUID
    var title: String
    var body: String
    var branchCount: Int = 1
}

enum HistoryPreview {
    private final class CacheEntry: NSObject {
        var text: String
        var preview: (title: String, body: String)

        init(text: String, preview: (title: String, body: String)) {
            self.text = text
            self.preview = preview
        }
    }

    private static let cache: NSCache<NSUUID, CacheEntry> = {
        let cache = NSCache<NSUUID, CacheEntry>()
        cache.countLimit = 4_096
        return cache
    }()

    static func ticks(from items: [ChatItem]) -> [HistoryTick] {
        items
            .filter { $0.kind == .user }
            .compactMap { item in
                let key = NSUUID(uuidString: item.id.uuidString)!
                let preview: (title: String, body: String)
                if let cached = cache.object(forKey: key), cached.text == item.text {
                    preview = cached.preview
                } else {
                    preview = make(from: item.text)
                    cache.setObject(CacheEntry(text: item.text, preview: preview), forKey: key)
                }
                guard !preview.title.isEmpty else { return nil }
                return HistoryTick(id: item.id, title: preview.title, body: preview.body)
            }
    }

    static func make(from text: String) -> (title: String, body: String) {
        let clipped = boundedPrefix(text, HistoryLimits.rawScanChars)
        var lines: [String] = []
        clipped.enumerateLines { line, _ in
            let trimmed = sanitizeLine(line)
            if !trimmed.isEmpty {
                lines.append(trimmed)
            }
        }
        if lines.isEmpty {
            let fallback = sanitizeLine(clipped)
            if fallback.isEmpty { return ("", "") }
            lines = [fallback]
        }
        let title = ellipsize(lines[0], HistoryLimits.maxTitleChars)
        let rest = lines.dropFirst().joined(separator: " ")
        let body = ellipsize(rest, HistoryLimits.maxBodyChars)
        return (title, body)
    }

    static func boundedPrefix(_ text: String, _ maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        var buffer = ""
        buffer.reserveCapacity(min(maxChars, 256))
        var count = 0
        for character in text {
            if count >= maxChars { break }
            buffer.append(character)
            count += 1
        }
        return buffer
    }

    static func ellipsize(_ text: String, _ maxChars: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxChars > 1 else { return "" }
        if trimmed.count <= maxChars { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxChars - 1)
        return String(trimmed[..<end]).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func sanitizeLine(_ line: String) -> String {
        let stripped = line.unicodeScalars.filter { scalar in
            scalar != "\t" && !CharacterSet.controlCharacters.contains(scalar)
        }
        return String(String.UnicodeScalarView(stripped))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct HistoryTickRail: View {
    var ticks: [HistoryTick]
    var viewportHeight: CGFloat
    var onSelect: (UUID) -> Void

    @State private var hoveredIndex: Int?
    @State private var animatedHoverPosition: CGFloat = 0
    @State private var visibleRowIDs: Set<String> = []
    @State private var hoverClear: DispatchWorkItem?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let height = max(viewportHeight, 24)
        let layout = HistoryRailLayout(count: ticks.count, viewportHeight: height)
        ZStack(alignment: .topLeading) {
            HistoryRailMarks(
                ticks: ticks,
                layout: layout,
                visibleRowIDs: visibleRowIDs,
                hoverPosition: animatedHoverPosition,
                isHovering: hoveredIndex != nil
            )
            .frame(width: HistoryLimits.gutter, height: height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    updateHover(at: location, layout: layout)
                case .ended:
                    setHovered(nil)
                }
            }
            .simultaneousGesture(
                SpatialTapGesture().onEnded { event in
                    guard let index = layout.index(at: event.location.y),
                          ticks.indices.contains(index) else { return }
                    onSelect(ticks[index].id)
                }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Conversation history")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Adjust to preview turns, then activate to jump")
            .accessibilityAdjustableAction { direction in
                let current = hoveredIndex ?? max(ticks.count - 1, 0)
                switch direction {
                case .increment:
                    setHovered(min(current + 1, ticks.count - 1))
                case .decrement:
                    setHovered(max(current - 1, 0))
                @unknown default:
                    break
                }
            }
            .accessibilityAction {
                guard let index = hoveredIndex, ticks.indices.contains(index) else { return }
                onSelect(ticks[index].id)
            }

            if let index = hoveredIndex, ticks.indices.contains(index) {
                previewCard(ticks[index])
                    .offset(
                        x: 20,
                        y: clampedCardY(
                            tickY: layout.y(for: index),
                            height: height
                        )
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .leading)))
                    .zIndex(2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: HistoryLimits.gutter, height: height, alignment: .topLeading)
        .animation(OverlayMotion.quick, value: hoveredIndex)
        .onReceive(NotificationCenter.default.publisher(for: .transcriptViewportChanged)) { note in
            guard let ids = note.userInfo?[TranscriptViewportUserInfoKey.visibleRowIDs] as? [String] else { return }
            visibleRowIDs = Set(ids)
        }
    }

    private func previewCard(_ tick: HistoryTick) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tick.title)
                .font(OverlayMetrics.font(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if !tick.body.isEmpty {
                Text(tick.body)
                    .font(OverlayMetrics.font(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tick.branchCount > 1 {
                Text("\(tick.branchCount) conversation paths")
                    .font(OverlayMetrics.font(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardFill)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var cardFill: Color {
        colorScheme == .dark
            ? Color(white: 0.16)
            : Color.white
    }

    private var accessibilityValue: String {
        guard let index = hoveredIndex, ticks.indices.contains(index) else {
            return "\(ticks.count) turns"
        }
        return "Turn \(index + 1) of \(ticks.count): \(ticks[index].title)"
    }

    private func updateHover(at point: CGPoint, layout: HistoryRailLayout) {
        guard let index = HistoryRailPolicy.hoveredIndex(
            at: point,
            layout: layout,
            gutter: HistoryLimits.gutter
        ) else {
            setHovered(nil)
            return
        }
        guard index != hoveredIndex else { return }
        setHovered(index)
    }

    private func setHovered(_ index: Int?) {
        hoverClear?.cancel()
        if let index {
            let wasHovering = hoveredIndex != nil
            hoveredIndex = index
            if wasHovering {
                withAnimation(OverlayMotion.quick) {
                    animatedHoverPosition = CGFloat(index)
                }
            } else {
                animatedHoverPosition = CGFloat(index)
            }
            return
        }
        let work = DispatchWorkItem {
            hoveredIndex = nil
        }
        hoverClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func clampedCardY(tickY: CGFloat, height: CGFloat) -> CGFloat {
        let card: CGFloat = 86
        return min(max(6, tickY - 10), max(6, height - card - 8))
    }
}

private struct HistoryRailMarks: View, Animatable {
    var ticks: [HistoryTick]
    var layout: HistoryRailLayout
    var visibleRowIDs: Set<String>
    var hoverPosition: CGFloat
    var isHovering: Bool

    var animatableData: CGFloat {
        get { hoverPosition }
        set { hoverPosition = newValue }
    }

    var body: some View {
        ZStack {
            // The 600-turn baseline is immutable while the viewport moves.
            // Rasterize it independently so a visible-row notification does
            // not rebuild hundreds of paths on every scroll frame.
            HistoryRailStaticMarks(ticks: ticks, layout: layout)
                .equatable()

            Canvas(rendersAsynchronously: true) { context, _ in
                for (index, tick) in ticks.enumerated()
                    where visibleRowIDs.contains(tick.id.uuidString) {
                    drawMark(
                        context: &context,
                        index: index,
                        width: 11,
                        height: 2.5,
                        opacity: 0.72
                    )
                }

                guard isHovering else { return }
                let center = min(max(Int(hoverPosition.rounded()), 0), max(0, ticks.count - 1))
                let lower = max(0, center - 3)
                let upper = min(ticks.count, center + 4)
                for index in lower..<upper {
                    let distance = abs(CGFloat(index) - hoverPosition)
                    guard distance < 3 else { continue }
                    drawMark(
                        context: &context,
                        index: index,
                        width: HistoryRailPolicy.width(distance: distance),
                        height: distance < 0.55 ? 3 : 2,
                        opacity: 0.88
                    )
                }
            }
        }
    }

    private func drawMark(
        context: inout GraphicsContext,
        index: Int,
        width: CGFloat,
        height: CGFloat,
        opacity: Double
    ) {
                let rect = CGRect(x: 6, y: layout.y(for: index) - height / 2, width: width, height: height)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: height / 2),
                    with: .color(Color.primary.opacity(opacity))
                )
    }
}

private struct HistoryRailStaticMarks: View, Equatable {
    let ticks: [HistoryTick]
    let layout: HistoryRailLayout

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, _ in
            for (index, tick) in ticks.enumerated() {
                let isLatest = index == ticks.count - 1
                let width: CGFloat = isLatest ? 9 : 7
                let height: CGFloat = 2
                let opacity = isLatest ? 0.46 : 0.20
                let rect = CGRect(
                    x: 6,
                    y: layout.y(for: index) - height / 2,
                    width: width,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: height / 2),
                    with: .color(Color.primary.opacity(opacity))
                )
                if tick.branchCount > 1 {
                    var branch = Path()
                    branch.move(to: CGPoint(x: rect.maxX - 1, y: rect.midY))
                    branch.addLine(to: CGPoint(x: min(rect.maxX + 5, 21), y: rect.midY - 3))
                    context.stroke(
                        branch,
                        with: .color(Color.primary.opacity(max(opacity - 0.12, 0.18))),
                        lineWidth: 1.5
                    )
                }
            }
        }
    }
}
