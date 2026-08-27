import Foundation

enum TranscriptHistoryWindow {
    static let initialTurnCapacity = 10
    static let earlierTurnPageSize = 20

    static func initialCapacity(environmentValue: String?) -> Int {
        guard let environmentValue,
              let requested = Int(environmentValue),
              requested > 0 else { return initialTurnCapacity }
        return requested
    }

    static func lowerBound(userRows: [Bool], turnCapacity: Int) -> Int {
        guard turnCapacity > 0 else { return userRows.count }
        var remaining = turnCapacity
        for index in userRows.indices.reversed() where userRows[index] {
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
