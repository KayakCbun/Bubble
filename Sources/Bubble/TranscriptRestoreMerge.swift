import Foundation

enum TranscriptRestoreMerge {
    static func merge<Row, ID: Hashable, StableKey: Hashable>(
        restored: [Row],
        live: [Row],
        id: (Row) -> ID,
        stableKey: (Row) -> StableKey?
    ) -> [Row] {
        let liveIDs = Set(live.map(id))
        let liveStableKeys = Set(live.compactMap(stableKey))
        return restored.filter { row in
            guard !liveIDs.contains(id(row)) else { return false }
            guard let key = stableKey(row) else { return true }
            return !liveStableKeys.contains(key)
        } + live
    }
}
