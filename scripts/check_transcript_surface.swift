import Foundation

private var failures: [String] = []

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}

private func row(
    _ id: String,
    version: UInt64 = 1,
    hash: String? = nil,
    height: CGFloat = 40,
    completed: Bool = true
) -> TranscriptRowSnapshot {
    TranscriptRowSnapshot(
        id: id,
        contentVersion: version,
        contentHash: hash ?? id,
        estimatedHeight: height,
        isCompleted: completed
    )
}

@main
private enum TranscriptSurfaceCheck {
    static func main() {
        expect(
            !TranscriptRowCompletionPolicy.workspaceCardIsCompleted(status: "running")
                && !TranscriptRowCompletionPolicy.workspaceCardIsCompleted(status: "waiting"),
            "active workspace cards stay mutable at the surface boundary"
        )
        expect(
            TranscriptRowCompletionPolicy.workspaceCardIsCompleted(status: "done")
                && TranscriptRowCompletionPolicy.workspaceCardIsCompleted(status: "failed")
                && TranscriptRowCompletionPolicy.workspaceCardIsCompleted(status: "interrupted"),
            "terminal workspace cards become immutable surface rows"
        )
        let session = TranscriptSessionHandle(sessionID: "main", generation: 1, revision: 0)
        let anchor = TranscriptSurfaceAnchor(rowID: "assistant-1", offset: 18.5)
        let initial = TranscriptSurfaceSnapshot(
            session: session,
            rows: [row("user-1"), row("assistant-1", height: 72, completed: false)],
            anchor: anchor,
            followsLatest: false
        )
        let adapter = RecordingTranscriptSurfaceAdapter(snapshot: initial)

        // A newer revision is accepted; replaying it is ignored.  A lower
        // generation is rejected even if it carries a large revision number.
        let revisionOne = session.nextRevision()
        let accepted = adapter.apply(
            .update(
                row: row("assistant-1", version: 2, hash: "assistant-v2", height: 88, completed: false),
                session: revisionOne,
                preserving: anchor
            )
        )
        expect(
            accepted.contains(where: {
                if case let .snapshotApplied(_, reused, invalidated, preserved) = $0 {
                    return reused.isEmpty && invalidated == ["assistant-1"] && preserved == anchor
                }
                return false
            }),
            "a newer row revision applies one invalidation and preserves its anchor"
        )
        let staleRevision = adapter.apply(
            .update(
                row: row("assistant-1", version: 3, hash: "stale"),
                session: revisionOne,
                preserving: anchor
            )
        )
        expect(
            staleRevision.contains(where: {
                if case .staleRevisionIgnored = $0 { return true }
                return false
            }),
            "a replayed revision is ignored at the adapter boundary"
        )
        let staleGeneration = adapter.apply(
            .replace(
                snapshot: TranscriptSurfaceSnapshot(
                    session: TranscriptSessionHandle(sessionID: "main", generation: 0, revision: 99),
                    rows: [row("stale")]
                )
            )
        )
        expect(
            staleGeneration.contains(where: {
                if case .staleGenerationIgnored = $0 { return true }
                return false
            }),
            "an older session generation cannot overwrite the current transcript"
        )

        // Stable content identities reuse completed rows while changed rows
        // are the only rows sent to layout invalidation.
        let revisionTwo = adapter.currentHandle.nextRevision()
        let reused = adapter.apply(
            .replace(
                snapshot: TranscriptSurfaceSnapshot(
                    session: revisionTwo,
                    rows: [
                        row("user-1"),
                        row("assistant-1", version: 4, hash: "assistant-v4", height: 96, completed: false),
                        row("tool-1", height: 24)
                    ],
                    anchor: anchor
                ),
                preserving: anchor
            )
        )
        expect(
            reused.contains(where: {
                if case let .snapshotApplied(_, ids, invalidated, _) = $0 {
                    return ids == ["user-1"] && invalidated == ["assistant-1", "tool-1"]
                }
                return false
            }),
            "replace reuses the unchanged row identity and invalidates only changed/new rows"
        )

        // Completed rows are immutable at this seam.  The adapter reports the
        // rejection and keeps the old content identity.
        let revisionThree = adapter.currentHandle.nextRevision()
        let immutable = adapter.apply(
            .update(
                row: row("user-1", version: 99, hash: "mutated"),
                session: revisionThree,
                preserving: anchor
            )
        )
        expect(
            immutable.contains(where: {
                if case let .completedRowMutationRejected(id) = $0 { return id == "user-1" }
                return false
            }),
            "completed row mutation is rejected"
        )
        expect(adapter.snapshot.row(id: "user-1")?.contentHash == "user-1", "completed row content stays immutable")

        // Disclosure is row-local and never emits a transcript-wide follow.
        let revisionFour = adapter.currentHandle.nextRevision()
        let disclosure = adapter.perform(
            .disclose(
                rowID: "assistant-1",
                expanded: true,
                session: revisionFour,
                preserving: anchor
            )
        )
        expect(adapter.interactionStore.isExpanded(rowID: "assistant-1"), "disclosure state is stored by row id")
        expect(!adapter.interactionStore.isExpanded(rowID: "user-1"), "unrelated rows stay collapsed")
        expect(
            disclosure.contains(where: {
                if case let .rowDisclosureChanged(_, id, expanded, invalidated, preserved) = $0 {
                    return id == "assistant-1" && expanded && invalidated == ["assistant-1"] && preserved == anchor
                }
                return false
            }),
            "disclosure invalidates exactly one row and carries its viewport anchor"
        )
        expect(
            !disclosure.contains(where: {
                if case .followLatestRequested = $0 { return true }
                return false
            }),
            "local disclosure cannot request transcript-wide follow-to-end"
        )
        expect(adapter.snapshot.anchor == anchor, "disclosure keeps the visible anchor in the snapshot")

        // Width, typography, scale, and local geometry all participate in the
        // key.  Width quantization avoids churn from sub-pixel geometry noise.
        let typography = TranscriptTypographyKey(fontFamily: "SF Pro", pointSize: 14, weight: 400, styleID: "prose")
        let baseKey = TranscriptLayoutCacheKey(
            rowID: "assistant-1",
            contentVersion: 4,
            contentHash: "assistant-v4",
            width: 400.001,
            typography: typography,
            scale: 2,
            geometry: TranscriptLocalGeometryState(isExpanded: true)
        )
        let subpixelKey = TranscriptLayoutCacheKey(
            rowID: "assistant-1",
            contentVersion: 4,
            contentHash: "assistant-v4",
            width: 400.006,
            typography: typography,
            scale: 2,
            geometry: TranscriptLocalGeometryState(isExpanded: true)
        )
        let widthKey = TranscriptLayoutCacheKey(
            rowID: "assistant-1",
            contentVersion: 4,
            contentHash: "assistant-v4",
            width: 401,
            typography: typography,
            scale: 2,
            geometry: TranscriptLocalGeometryState(isExpanded: true)
        )
        let fontKey = TranscriptLayoutCacheKey(
            rowID: "assistant-1",
            contentVersion: 4,
            contentHash: "assistant-v4",
            width: 400,
            typography: TranscriptTypographyKey(fontFamily: "SF Mono", pointSize: 14, weight: 400, styleID: "code"),
            scale: 2,
            geometry: TranscriptLocalGeometryState(isExpanded: true)
        )
        let disclosureKey = TranscriptLayoutCacheKey(
            rowID: "assistant-1",
            contentVersion: 4,
            contentHash: "assistant-v4",
            width: 400,
            typography: typography,
            scale: 2,
            geometry: TranscriptLocalGeometryState(isExpanded: false)
        )
        let layoutVersionKey = TranscriptLayoutCacheKey(
            rowID: "assistant-1",
            contentVersion: 4,
            contentHash: "assistant-v4",
            width: 400,
            typography: typography,
            scale: 2,
            geometry: TranscriptLocalGeometryState(isExpanded: true),
            layoutVersion: TranscriptTypographyKey.defaultLayoutVersion + 1
        )
        expect(baseKey == subpixelKey, "cache key quantizes harmless sub-pixel width noise")
        expect(baseKey != widthKey, "cache key changes when available width changes")
        expect(baseKey != fontKey, "cache key changes when font/style changes")
        expect(baseKey != disclosureKey, "cache key changes when local disclosure geometry changes")
        expect(baseKey != layoutVersionKey, "cache key changes when the layout version changes")

        // The LRU is bounded and distinguishes the layout variants above.
        let cache = TranscriptHeightCache(capacity: 2)
        cache.insert(80, for: baseKey)
        cache.insert(90, for: widthKey)
        _ = cache.value(for: baseKey) // make base the most recent entry
        cache.insert(100, for: fontKey)
        expect(cache.count == 2, "height cache never exceeds its configured bound")
        expect(cache.value(for: widthKey) == nil, "least-recently-used layout height is evicted")
        expect(cache.value(for: baseKey) == 80, "height cache retains the recently-used width variant")
        expect(cache.value(for: fontKey) == 100, "font/style variant has an independent cached height")

        // Projection caches are keyed by the caller's immutable projection
        // inputs.  An unrelated body evaluation (for example, a composer
        // draft keystroke) must return the same value without rebuilding the
        // O(N) row list.
        let projection = TranscriptProjectionCache<String, [Int]>()
        _ = projection.value(for: "transcript-v1") { [1, 2, 3] }
        _ = projection.value(for: "transcript-v1") { [4, 5, 6] }
        expect(projection.buildCount == 1, "same projection key reuses its immutable value")
        expect(projection.value(for: "transcript-v1", make: { [1, 2, 3] }) == [1, 2, 3], "projection cache returns the original value")
        _ = projection.value(for: "transcript-v2") { [7, 8] }
        expect(projection.buildCount == 2, "a changed projection key performs one new build")

        // A newer generation starts from an explicit replacement and does not
        // inherit stale rows or disclosure state.
        let generationTwo = TranscriptSessionHandle(sessionID: "main", generation: 2, revision: 0)
        let generationEvents = adapter.apply(
            .replace(
                snapshot: TranscriptSurfaceSnapshot(
                    session: generationTwo,
                    rows: [row("new-session")],
                    anchor: nil,
                    followsLatest: true
                )
            )
        )
        expect(
            generationEvents.contains(where: {
                if case let .snapshotApplied(handle, _, invalidated, _) = $0 {
                    return handle == generationTwo && invalidated == ["new-session"]
                }
                return false
            }),
            "a newer generation accepts an explicit replacement"
        )
        expect(adapter.snapshot.rowIDs == ["new-session"], "generation replacement drops stale rows")
        expect(adapter.snapshot.followsLatest, "replacement preserves the caller's follow mode")

        if failures.isEmpty {
            print("PASS: transcript surface core stale/reuse/disclosure/cache/anchor invariants")
        } else {
            for failure in failures {
                FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
            }
            exit(1)
        }
    }
}
