import Foundation

/// A source row plus the immutable render seed derived from it.
///
/// The projection store deliberately does not own views or SwiftUI state.  A
/// caller may therefore keep `Source` as a rich domain value (for Bubble this
/// is `TranscriptRow`) while the store owns only stable identities, seeds and
/// the render plan boundary.
struct TranscriptProjectionRecord<Source> {
    let id: String
    let seed: TranscriptRenderSeed
    let source: Source

    init(id: String, seed: TranscriptRenderSeed, source: Source) {
        self.id = id
        self.seed = seed
        self.source = source
    }
}

/// Explicit mutations accepted by the projection boundary.  Streaming paths
/// should use `.update` or `.append`; session restore, branch changes and
/// history-window changes use `.replace` so the store can safely rebuild its
/// structural index.  An update for an unknown id is rejected instead of
/// silently inserting at a guessed position (which would corrupt chunk and
/// scroll anchors).
enum TranscriptProjectionDelta<Source> {
    case replace(records: [TranscriptProjectionRecord<Source>])
    case append(records: [TranscriptProjectionRecord<Source>])
    case update(record: TranscriptProjectionRecord<Source>)
    case remove(ids: [String])
}

struct TranscriptProjectionWork: Equatable, Sendable {
    enum Mode: String, Sendable {
        case cold
        case cached
        case incremental
        case rebuilt
        case rejected
    }

    var mode: Mode = .cold
    /// Number of records whose identity was inspected while applying the
    /// delta.  A live tail update must stay at one, independent of history.
    var inspectedRecordCount = 0
    /// Number of records whose seed/source pair was rebuilt or replaced.
    var rebuiltRecordCount = 0
    /// Number of records updated in-place in their segment.
    var updatedRecordCount = 0
    /// Number of records copied into a caller-owned array by materialization.
    var materializedRecordCount = 0
    /// Structural operations can report the affected identities for focused
    /// checks and production diagnostics without retaining the old snapshot.
    var changedIDs: [String] = []

    static let cached = TranscriptProjectionWork(mode: .cached)
}

struct TranscriptProjectionMaterialization<Source> {
    let range: Range<Int>
    let records: [TranscriptProjectionRecord<Source>]
    let work: TranscriptProjectionWork
}

/// Segmented, reference-backed transcript projection storage.
///
/// A Swift `Array` of 4,000 rows is cheap to read but expensive to mutate once
/// another value still shares its buffer.  This store keeps fixed-size
/// reference-backed segments instead.  Updating a streamed tail mutates one
/// segment and one index entry; it never copies the immutable prefix.  A
/// structural mutation intentionally rebuilds all segments and is surfaced in
/// `lastWork` so callers can audit that fallback.
final class TranscriptProjectionStore<Source> {
    private struct Position {
        let segment: Int
        let offset: Int
        let index: Int
    }

    private final class Segment {
        var records: [TranscriptProjectionRecord<Source>]

        init(records: [TranscriptProjectionRecord<Source>] = []) {
            self.records = records
        }
    }

    /// 64 rows keeps a 4,000-row transcript at ~63 segment objects while
    /// bounding an in-place update's local storage and index churn.
    let segmentCapacity: Int

    private var segments: [Segment] = []
    private var positions: [String: Position] = [:]
    /// Grouped transcript rows (for example `tool-<item id>`) do not always
    /// share the ChatStore item's identity. This reverse index lets a source
    /// delta still find its owning render row without scanning history.
    private var recordIDBySourceID: [String: String] = [:]
    /// The flat seed buffer is only exposed read-only to the planner.  Since
    /// the store is its sole owner, assigning one streamed seed is O(1) and
    /// does not trigger Array COW.  Structural replacements recreate it.
    private var seedBuffer: [TranscriptRenderSeed] = []
    /// Nearest owning user turn for each seed. Rebuilt only on structural
    /// changes, this keeps history-rail mapping O(1) during token updates.
    private var userTickBuffer: [String?] = []

    private(set) var lastWork = TranscriptProjectionWork()
    private(set) var generation: UInt64 = 0

    init(segmentCapacity: Int = 64) {
        self.segmentCapacity = max(1, segmentCapacity)
    }

    var count: Int { seedBuffer.count }
    var isEmpty: Bool { seedBuffer.isEmpty }
    var ids: [String] { seedBuffer.map(\.id) }

    /// Number of segment objects currently backing the projection.  This is
    /// intentionally diagnostic-only; callers should not depend on layout.
    var segmentCount: Int { segments.count }

    /// The planner receives this value without mutating it.  The returned
    /// array shares the store's buffer and therefore remains allocation-free
    /// for a streaming update until a caller writes to its own copy.
    var seeds: [TranscriptRenderSeed] { seedBuffer }

    func historyTickID(at index: Int) -> String? {
        guard userTickBuffer.indices.contains(index) else { return nil }
        return userTickBuffer[index]
    }

    func record(at index: Int) -> TranscriptProjectionRecord<Source>? {
        guard index >= 0, index < count else { return nil }
        let location = location(of: index)
        return segments[location.segment].records[location.offset]
    }

    func record(id: String) -> TranscriptProjectionRecord<Source>? {
        guard let location = positions[id] else { return nil }
        return segments[location.segment].records[location.offset]
    }

    func record(sourceID: String) -> TranscriptProjectionRecord<Source>? {
        guard let recordID = recordIDBySourceID[sourceID] else { return nil }
        return record(id: recordID)
    }

    func index(of id: String) -> Int? {
        positions[id]?.index
    }

    /// Apply an explicit mutation.  Rejected deltas leave the previous
    /// projection untouched; callers should issue a `.replace` using their
    /// authoritative structural source when this happens.
    @discardableResult
    func apply(_ delta: TranscriptProjectionDelta<Source>) -> TranscriptProjectionWork {
        switch delta {
        case .replace(let records):
            replace(records)
            return lastWork
        case .append(let records):
            return append(records)
        case .update(let record):
            return update(record)
        case .remove(let ids):
            return remove(ids: ids)
        }
    }

    /// Materialize only the requested flattened range.  A range is commonly
    /// the adapter's overscanned viewport; a full snapshot remains available
    /// by passing `0..<count` for structural updates and diagnostics.
    func materialize(_ requestedRange: Range<Int>) -> TranscriptProjectionMaterialization<Source> {
        let lower = max(0, min(count, requestedRange.lowerBound))
        let upper = max(lower, min(count, requestedRange.upperBound))
        let range = lower..<upper
        var records: [TranscriptProjectionRecord<Source>] = []
        records.reserveCapacity(range.count)
        for index in range {
            if let record = record(at: index) {
                records.append(record)
            }
        }
        var work = TranscriptProjectionWork(
            mode: .cached,
            inspectedRecordCount: 0,
            rebuiltRecordCount: 0,
            updatedRecordCount: 0,
            materializedRecordCount: records.count,
            changedIDs: records.map(\.id)
        )
        // Keep the mutation mode visible to diagnostics while exposing the
        // concrete cost of this call.
        if lastWork.mode == .incremental {
            work.mode = .incremental
        } else if lastWork.mode == .rebuilt || lastWork.mode == .cold {
            work.mode = lastWork.mode
        }
        lastWork = work
        return TranscriptProjectionMaterialization(range: range, records: records, work: work)
    }

    /// Clears all storage and starts a new generation.  This is used when a
    /// Pi session identity changes; no stale rows can survive that boundary.
    func reset() {
        segments.removeAll(keepingCapacity: true)
        positions.removeAll(keepingCapacity: true)
        recordIDBySourceID.removeAll(keepingCapacity: true)
        seedBuffer.removeAll(keepingCapacity: true)
        userTickBuffer.removeAll(keepingCapacity: true)
        generation &+= 1
        lastWork = TranscriptProjectionWork(mode: .cold)
    }

    private func replace(_ records: [TranscriptProjectionRecord<Source>]) {
        var seen = Set<String>()
        guard records.allSatisfy({ !$0.id.isEmpty && seen.insert($0.id).inserted }) else {
            lastWork = TranscriptProjectionWork(mode: .rejected)
            return
        }
        segments.removeAll(keepingCapacity: true)
        positions.removeAll(keepingCapacity: true)
        recordIDBySourceID.removeAll(keepingCapacity: true)
        seedBuffer.removeAll(keepingCapacity: true)
        userTickBuffer.removeAll(keepingCapacity: true)
        seedBuffer.reserveCapacity(records.count)
        userTickBuffer.reserveCapacity(records.count)
        segments.reserveCapacity((records.count + segmentCapacity - 1) / segmentCapacity)

        var segment = Segment()
        segment.records.reserveCapacity(segmentCapacity)
        for record in records {
            if segment.records.count == segmentCapacity {
                segments.append(segment)
                segment = Segment()
                segment.records.reserveCapacity(segmentCapacity)
            }
            let segmentIndex = segments.count
            positions[record.id] = Position(
                segment: segmentIndex,
                offset: segment.records.count,
                index: seedBuffer.count
            )
            for sourceID in record.seed.sourceIDs {
                recordIDBySourceID[sourceID] = record.id
            }
            segment.records.append(record)
            seedBuffer.append(record.seed)
            let previousUser = userTickBuffer.last ?? nil
            userTickBuffer.append(record.seed.kind == .user ? record.id : previousUser)
        }
        if !segment.records.isEmpty { segments.append(segment) }
        generation &+= 1
        lastWork = TranscriptProjectionWork(
            mode: records.isEmpty ? .cold : .rebuilt,
            inspectedRecordCount: records.count,
            rebuiltRecordCount: records.count,
            changedIDs: records.map(\.id)
        )
    }

    private func append(_ records: [TranscriptProjectionRecord<Source>]) -> TranscriptProjectionWork {
        guard !records.isEmpty else {
            lastWork = .cached
            return lastWork
        }
        var seen = Set<String>()
        guard records.allSatisfy({ !$0.id.isEmpty && seen.insert($0.id).inserted && positions[$0.id] == nil }) else {
            lastWork = TranscriptProjectionWork(mode: .rejected)
            return lastWork
        }

        var rebuiltSegments = 0
        for record in records {
            if segments.last?.records.count == segmentCapacity {
                segments.append(Segment())
                rebuiltSegments += 1
            }
            if segments.isEmpty { segments.append(Segment()) }
            let segmentIndex = segments.count - 1
            let offset = segments[segmentIndex].records.count
            segments[segmentIndex].records.append(record)
            positions[record.id] = Position(
                segment: segmentIndex,
                offset: offset,
                index: seedBuffer.count
            )
            for sourceID in record.seed.sourceIDs {
                recordIDBySourceID[sourceID] = record.id
            }
            seedBuffer.append(record.seed)
            let previousUser = userTickBuffer.last ?? nil
            userTickBuffer.append(record.seed.kind == .user ? record.id : previousUser)
        }
        lastWork = TranscriptProjectionWork(
            mode: .incremental,
            inspectedRecordCount: records.count,
            rebuiltRecordCount: rebuiltSegments,
            updatedRecordCount: records.count,
            changedIDs: records.map(\.id)
        )
        return lastWork
    }

    private func update(_ record: TranscriptProjectionRecord<Source>) -> TranscriptProjectionWork {
        guard let location = positions[record.id] else {
            lastWork = TranscriptProjectionWork(mode: .rejected, changedIDs: [record.id])
            return lastWork
        }
        let previous = segments[location.segment].records[location.offset]
        // A kind/source-group mutation changes all following tick ownership;
        // force the caller through the structural replacement path.
        guard previous.seed.kind == record.seed.kind,
              previous.seed.sourceIDs == record.seed.sourceIDs,
              previous.seed.hasMedia == record.seed.hasMedia else {
            lastWork = TranscriptProjectionWork(mode: .rejected, changedIDs: [record.id])
            return lastWork
        }
        segments[location.segment].records[location.offset] = record
        let index = location.index
        seedBuffer[index] = record.seed
        if record.seed.kind == .user {
            userTickBuffer[index] = record.id
        }
        lastWork = TranscriptProjectionWork(
            mode: .incremental,
            inspectedRecordCount: 1,
            rebuiltRecordCount: 0,
            updatedRecordCount: 1,
            changedIDs: [record.id]
        )
        return lastWork
    }

    private func remove(ids: [String]) -> TranscriptProjectionWork {
        guard !ids.isEmpty else {
            lastWork = .cached
            return lastWork
        }
        let removing = Set(ids)
        guard removing.count == ids.count,
              ids.allSatisfy({ positions[$0] != nil }) else {
            lastWork = TranscriptProjectionWork(mode: .rejected, changedIDs: ids)
            return lastWork
        }
        let remaining = segments.flatMap(\.records).filter { !removing.contains($0.id) }
        replace(remaining)
        lastWork.mode = .rebuilt
        lastWork.changedIDs = ids
        return lastWork
    }

    private func location(of index: Int) -> (segment: Int, offset: Int) {
        // Segments are fixed-capacity contiguous blocks. Deriving the owner
        // arithmetically avoids walking every preceding segment for a tail
        // token update (and remains valid for a partially filled final block).
        let clamped = max(0, min(max(0, count - 1), index))
        let segment = min(max(0, segments.count - 1), clamped / segmentCapacity)
        return (segment, clamped % segmentCapacity)
    }
}
