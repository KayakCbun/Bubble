import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func record(_ index: Int, suffix: String = "") -> TranscriptProjectionRecord<Int> {
    let id = "row-\(index)"
    let seed = TranscriptRenderSeed(
        id: id,
        kind: index.isMultiple(of: 2) ? .assistant : .user,
        text: "text \(index)\(suffix)"
    )
    return TranscriptProjectionRecord(id: id, seed: seed, source: index)
}

@main
private enum TranscriptProjectionStoreCheck {
    static func main() {
        checkSmallDeltaContract()
        checkLongSession(600)
        checkLongSession(4_000)
        print("PASS: transcript projection store")
    }

    private static func checkSmallDeltaContract() {
        let store = TranscriptProjectionStore<Int>(segmentCapacity: 4)
        let initial = (0..<12).map { record($0) }
        let cold = store.apply(.replace(records: initial))
        expect(cold.mode == .rebuilt, "replace reports structural rebuild")
        expect(store.count == 12 && store.segmentCount == 3, "replace partitions records into fixed segments")
        expect(store.record(at: 7)?.source == 7, "record lookup preserves source payload")
        expect(store.index(of: "row-7") == 7, "id index resolves the flattened position")

        let beforePrefix = (0..<11).compactMap { store.record(at: $0)?.seed.text }
        let update = store.apply(.update(record: record(11, suffix: "-stream-1")))
        expect(update.mode == .incremental, "tail update uses incremental mode")
        expect(update.inspectedRecordCount == 1, "tail update inspects one identity")
        expect(update.updatedRecordCount == 1 && update.rebuiltRecordCount == 0, "tail update mutates one segment in place")
        expect(update.materializedRecordCount == 0, "tail update does not materialize a full snapshot")
        expect((0..<11).compactMap { store.record(at: $0)?.seed.text } == beforePrefix, "tail update preserves immutable prefix")
        expect(store.record(id: "row-11")?.seed.text == "text 11-stream-1", "tail update publishes the new seed")

        let window = store.materialize(8..<12)
        expect(window.range == 8..<12 && window.records.count == 4, "range materialization returns only the requested adapter window")
        expect(window.work.materializedRecordCount == 4, "materialization reports copied records")
        expect(window.records.first?.source == 8 && window.records.last?.source == 11, "materialized range keeps order")

        let appended = store.apply(.append(records: [record(12), record(13)]))
        expect(appended.mode == .incremental && store.count == 14, "append extends the projection without rebuild")
        expect(store.index(of: "row-13") == 13, "append updates the id index")

        let groupedSeed = TranscriptRenderSeed(
            id: "tool-source-row",
            kind: .other,
            text: "tool-v1",
            sourceIDs: ["tool-source-id"]
        )
        _ = store.apply(.append(records: [TranscriptProjectionRecord(
            id: "tool-source-row",
            seed: groupedSeed,
            source: 14
        )]))
        expect(
            store.record(sourceID: "tool-source-id")?.id == "tool-source-row",
            "grouped presentation rows resolve source-item deltas in O(1)"
        )

        let rejected = store.apply(.update(record: record(999)))
        expect(rejected.mode == .rejected, "unknown update is rejected for structural safety")
        expect(store.count == 15, "rejected update leaves the previous projection intact")

        let removed = store.apply(.remove(ids: ["row-0"]))
        expect(removed.mode == .rebuilt && store.count == 14, "remove uses an explicit structural rebuild")
        expect(store.record(at: 0)?.id == "row-1", "remove preserves remaining order")

        let generation = store.generation
        store.reset()
        expect(store.count == 0 && store.generation > generation, "reset clears rows and advances generation")
    }

    private static func checkLongSession(_ count: Int) {
        let store = TranscriptProjectionStore<Int>(segmentCapacity: 64)
        let initial = (0..<count).map { record($0) }
        _ = store.apply(.replace(records: initial))
        let expectedSegments = (count + 63) / 64
        expect(store.segmentCount == expectedSegments, "\(count)-row session uses bounded segment count")

        let prefixIDs = (0..<min(128, count)).compactMap { store.record(at: $0)?.id }
        var durations: [Double] = []
        durations.reserveCapacity(80)
        for version in 0..<80 {
            let started = ProcessInfo.processInfo.systemUptime
            let work = store.apply(.update(record: record(count - 1, suffix: "-v\(version)")))
            durations.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            expect(work.inspectedRecordCount == 1, "\(count)-row token update stays O(1)")
            expect(work.materializedRecordCount == 0, "\(count)-row token update avoids full materialization")
            expect(work.rebuiltRecordCount == 0, "\(count)-row token update does not rebuild segments")
        }
        let sorted = durations.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        expect(p95 < 5, "\(count)-row tail update p95 stays under 5ms, got \(p95)ms")
        expect((0..<min(128, count)).compactMap { store.record(at: $0)?.id } == prefixIDs, "\(count)-row prefix remains byte-for-byte stable")

        let visible = store.materialize((count / 2)..<min(count / 2 + 24, count))
        expect(visible.records.count == min(24, count - count / 2), "\(count)-row viewport materializes only its requested range")
        expect(visible.work.materializedRecordCount == visible.records.count, "\(count)-row range reports bounded copy work")
    }
}
