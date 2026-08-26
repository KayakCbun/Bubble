import Foundation

struct HistoryRailLayout: Equatable {
    static let inset: CGFloat = 10
    static let preferredStep: CGFloat = 8

    var count: Int
    var viewportHeight: CGFloat
    var originY: CGFloat
    var step: CGFloat

    init(count: Int, viewportHeight: CGFloat) {
        self.count = max(count, 0)
        self.viewportHeight = max(viewportHeight, 24)
        let intervals = max(count - 1, 0)
        let available = max(self.viewportHeight - Self.inset * 2, 1)
        let natural = CGFloat(intervals) * Self.preferredStep
        let railHeight = min(natural, available)
        originY = ((self.viewportHeight - railHeight) / 2).rounded()
        step = intervals > 0 ? railHeight / CGFloat(intervals) : 0
    }

    var railHeight: CGFloat {
        step * CGFloat(max(count - 1, 0))
    }

    func y(for index: Int) -> CGFloat {
        guard count > 1 else { return viewportHeight / 2 }
        let clamped = min(max(index, 0), count - 1)
        return originY + CGFloat(clamped) * step
    }

    func index(at y: CGFloat) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1, step > 0 else { return 0 }
        return min(max(Int(((y - originY) / step).rounded()), 0), count - 1)
    }
}

enum HistoryRailPolicy {
    static func hoveredIndex(
        at point: CGPoint,
        layout: HistoryRailLayout,
        gutter: CGFloat
    ) -> Int? {
        guard point.x >= 5, point.x <= gutter,
              let index = layout.index(at: point.y) else { return nil }
        let tolerance = max(2, min(4, layout.step * 0.45))
        return abs(point.y - layout.y(for: index)) <= tolerance ? index : nil
    }

    static func visibleTurnIndexes(
        turnStarts: [CGFloat],
        documentMaxY: CGFloat,
        viewportMinY: CGFloat,
        viewportMaxY: CGFloat
    ) -> IndexSet {
        var result = IndexSet()
        for index in turnStarts.indices {
            let start = turnStarts[index]
            let end = index + 1 < turnStarts.count ? turnStarts[index + 1] : documentMaxY
            if intersectsViewport(
                rowMinY: start,
                rowMaxY: max(start, end),
                viewportMinY: viewportMinY,
                viewportMaxY: viewportMaxY
            ) {
                result.insert(index)
            }
        }
        return result
    }

    static func intersectsViewport(
        rowMinY: CGFloat,
        rowMaxY: CGFloat,
        viewportMinY: CGFloat,
        viewportMaxY: CGFloat
    ) -> Bool {
        rowMinY < viewportMaxY && rowMaxY > viewportMinY
    }

    static func width(distance: CGFloat) -> CGFloat {
        let stops: [(CGFloat, CGFloat)] = [(0, 16), (1, 12), (2, 8), (3, 6)]
        let value = max(distance, 0)
        guard value < 3 else { return 6 }
        let lower = Int(floor(value))
        let progress = value - CGFloat(lower)
        return stops[lower].1 + (stops[lower + 1].1 - stops[lower].1) * progress
    }
}
