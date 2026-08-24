import SwiftUI

enum HistoryLimits {
    static let maxTurns = 30
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
    static func ticks(from items: [ChatItem]) -> [HistoryTick] {
        items
            .filter { $0.kind == .user }
            .suffix(HistoryLimits.maxTurns)
            .compactMap { item in
                let preview = make(from: item.text)
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

    @State private var hovered: UUID?
    @State private var hoverClear: DispatchWorkItem?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let height = max(viewportHeight, 24)
        let layout = TickLayout(count: ticks.count, height: height)
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: layout.gap) {
                ForEach(Array(ticks.enumerated()), id: \.element.id) { index, tick in
                    tickMark(tick, isLast: index == ticks.count - 1)
                }
            }
            .padding(.leading, 6)
            .frame(height: height, alignment: .center)

            if let hovered, let index = ticks.firstIndex(where: { $0.id == hovered }) {
                previewCard(ticks[index])
                    .offset(
                        x: 20,
                        y: clampedCardY(
                            tickY: layout.y(index: index),
                            height: height
                        )
                    )
                    .zIndex(2)
            }
        }
        .frame(height: height, alignment: .leading)
        .animation(OverlayMotion.quick, value: hovered)
    }

    private func tickMark(_ tick: HistoryTick, isLast: Bool) -> some View {
        let active = hovered == tick.id
        return Button {
            onSelect(tick.id)
        } label: {
            HStack(spacing: 1.5) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(active ? 0.82 : (isLast ? 0.45 : 0.22)))
                    .frame(width: active ? 12 : (isLast ? 9 : 7), height: active ? 3 : 1.5)
                if tick.branchCount > 1 {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(active ? 0.72 : 0.30))
                        .frame(width: active ? 7 : 5, height: active ? 3 : 1.5)
                        .rotationEffect(.degrees(-24), anchor: .leading)
                }
            }
                .frame(width: 18, height: 8, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            setHovered(inside ? tick.id : nil)
        }
    }

    private func previewCard(_ tick: HistoryTick) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tick.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if !tick.body.isEmpty {
                Text(tick.body)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tick.branchCount > 1 {
                Text("\(tick.branchCount) conversation paths")
                    .font(.system(size: 10.5, weight: .medium))
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
        .onHover { inside in
            setHovered(inside ? tick.id : nil)
        }
    }

    private var cardFill: Color {
        colorScheme == .dark
            ? Color(white: 0.16).opacity(0.8)
            : Color.white.opacity(0.8)
    }

    private func setHovered(_ id: UUID?) {
        hoverClear?.cancel()
        if let id {
            hovered = id
            return
        }
        let work = DispatchWorkItem {
            hovered = nil
        }
        hoverClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func clampedCardY(tickY: CGFloat, height: CGFloat) -> CGFloat {
        let card: CGFloat = 86
        return min(max(6, tickY - 10), max(6, height - card - 8))
    }
}

private struct TickLayout {
    var gap: CGFloat
    var step: CGFloat
    var originY: CGFloat

    init(count: Int, height: CGFloat) {
        let inset: CGFloat = 10
        let usable = max(height - inset * 2, 24)
        let n = max(count, 1)
        let tick: CGFloat = 8
        let preferred: CGFloat = 5
        let natural = CGFloat(n) * tick + CGFloat(max(n - 1, 0)) * preferred
        if natural <= usable {
            gap = preferred
            originY = ((height - natural) / 2).rounded()
        } else {
            gap = max(2, (usable - CGFloat(n) * tick) / CGFloat(max(n - 1, 1)))
            originY = inset
        }
        step = tick + gap
    }

    func y(index: Int) -> CGFloat {
        originY + CGFloat(index) * step
    }
}
