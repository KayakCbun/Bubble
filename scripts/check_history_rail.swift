import Foundation

@main
enum CheckHistoryRail {
    static func main() {
        let layout = HistoryRailLayout(count: 101, viewportHeight: 220)
        precondition(layout.step <= 8.01, "history marks should stay densely packed")
        precondition(abs(layout.y(for: 0) - 10) < 0.01)
        precondition(abs(layout.y(for: 100) - 210) < 0.01)

        precondition(layout.index(at: -20) == 0)
        precondition(layout.index(at: 210) == 100)
        precondition(layout.index(at: 110) == 50)

        precondition(HistoryRailPolicy.intersectsViewport(
            rowMinY: 180,
            rowMaxY: 260,
            viewportMinY: 200,
            viewportMaxY: 400
        ))
        precondition(!HistoryRailPolicy.intersectsViewport(
            rowMinY: 100,
            rowMaxY: 200,
            viewportMinY: 200,
            viewportMaxY: 400
        ))

        precondition(HistoryRailPolicy.visibleTurnIndexes(
            turnStarts: [0, 300, 900],
            documentMaxY: 1_500,
            viewportMinY: 250,
            viewportMaxY: 650
        ) == IndexSet([0, 1]))
        precondition(HistoryRailPolicy.visibleTurnIndexes(
            turnStarts: [0, 300, 900],
            documentMaxY: 1_500,
            viewportMinY: 1_100,
            viewportMaxY: 1_300
        ) == IndexSet(integer: 2))

        precondition(HistoryRailPolicy.width(distance: 0) == 16)
        precondition(HistoryRailPolicy.width(distance: 1) == 12)
        precondition(HistoryRailPolicy.width(distance: 2) == 8)
        precondition(HistoryRailPolicy.width(distance: 3) == 6)
        precondition(
            HistoryRailPolicy.hoveredIndex(
                at: CGPoint(x: 12, y: layout.y(for: 50)),
                layout: layout,
                gutter: 22
            ) == 50
        )
        precondition(
            HistoryRailPolicy.hoveredIndex(
                at: CGPoint(x: 36, y: layout.y(for: 50)),
                layout: layout,
                gutter: 22
            ) == nil,
            "blank transcript margin must not activate history"
        )
        let sparse = HistoryRailLayout(count: 3, viewportHeight: 220)
        precondition(
            HistoryRailPolicy.hoveredIndex(
                at: CGPoint(x: 12, y: 60),
                layout: sparse,
                gutter: 22
            ) == nil,
            "vertical space between visible ticks must not activate history"
        )

        print("history rail policy checks passed")
    }
}
