import Foundation

enum TranscriptHistoryWindow {
    static let initialTurnCapacity = 10
    static let earlierTurnPageSize = 20

    static var configuredInitialCapacity: Int {
        initialCapacity(
            environmentValue: ProcessInfo.processInfo.environment["BUBBLE_TRANSCRIPT_HISTORY_TURNS"]
        )
    }

    static func initialCapacity(environmentValue: String?) -> Int {
        guard let environmentValue,
              let requested = Int(environmentValue),
              requested > 0 else { return initialTurnCapacity }
        return requested
    }

    static func lowerBound<Row>(
        rows: [Row],
        turnCapacity: Int,
        isUser: (Row) -> Bool
    ) -> Int {
        guard turnCapacity > 0 else { return rows.count }
        var remaining = turnCapacity
        for index in rows.indices.reversed() where isUser(rows[index]) {
            remaining -= 1
            if remaining == 0 {
                return index
            }
        }
        return 0
    }

    static func expandedCapacity(current: Int, totalTurns: Int) -> Int {
        min(max(totalTurns, 0), max(current, 0) + earlierTurnPageSize)
    }
}

enum TranscriptHydrationTiming {
    nonisolated(unsafe) private(set) static var diagnosticStartedAt: TimeInterval?

    static func startIfDiagnosing() {
        guard ProcessInfo.processInfo.environment["BUBBLE_SCROLL_DIAGNOSTICS"] != nil else { return }
        diagnosticStartedAt = ProcessInfo.processInfo.systemUptime
    }

    static func clear() {
        diagnosticStartedAt = nil
    }
}
