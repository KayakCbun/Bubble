import AppKit
import Foundation

private var failures: [String] = []
private var streamingTailP95MS: Double = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}

private func row(
    _ id: String,
    version: UInt64 = 1,
    height: CGFloat = 32,
    text: String? = nil,
    completed: Bool = true
) -> TranscriptRowSnapshot {
    TranscriptRowSnapshot(
        id: id,
        contentVersion: version,
        contentHash: id + "-" + String(version),
        estimatedHeight: height,
        isCompleted: completed,
        kind: .assistant,
        text: text
    )
}

/// A host whose rich content is taller than the producer estimate.  This
/// models a freshly mounted SwiftUI row before its asynchronous intrinsic-size
/// callback has run; the adapter must synchronously reconcile the visible
/// frame before exposing it to the viewport.
private final class FirstMountMeasurementHost: AppKitTranscriptRowHost {
    private let measuredHeight: CGFloat
    private let requiresImmediateMeasurement: Bool

    init(
        row: TranscriptRowSnapshot,
        key: AppKitTranscriptRowReuseKey,
        measuredHeight: CGFloat,
        requiresImmediateMeasurement: Bool = false
    ) {
        self.measuredHeight = measuredHeight
        self.requiresImmediateMeasurement = requiresImmediateMeasurement
        super.init(row: row, key: key)
    }

    override var preferredContentHeight: CGFloat { measuredHeight }
    override var needsImmediateContentMeasurement: Bool { requiresImmediateMeasurement }
}

/// Models a restored NSHostingView whose first fitting pass still reflects
/// the previous/empty SwiftUI transaction. The rich content settles on the
/// next run-loop turn and must be explicitly remeasured even without wheel
/// input; otherwise historical rows remain permanently clipped.
private final class RestoredSessionMeasurementHost: AppKitTranscriptRowHost {
    private let settledHeight: CGFloat
    private var measuredHeight: CGFloat

    init(row: TranscriptRowSnapshot, key: AppKitTranscriptRowReuseKey, settledHeight: CGFloat) {
        self.settledHeight = settledHeight
        self.measuredHeight = row.estimatedHeight
        super.init(row: row, key: key)
    }

    override var preferredContentHeight: CGFloat { measuredHeight }

    override func invalidateContentMeasurement() {
        measuredHeight = settledHeight
    }
}

/// A window-addressed event lets the focused harness pass through
/// `NSApplication.sendEvent` and the production local event monitor without
/// requiring accessibility permission or posting a global HID event.
private final class WindowRoutedWheelEvent: NSEvent {
    private let targetWindowNumber: Int
    private let targetLocation: NSPoint
    private let wheelDeltaX: CGFloat
    private let wheelDeltaY: CGFloat

    init(windowNumber: Int, location: NSPoint, deltaX: CGFloat = 0, deltaY: CGFloat) {
        self.targetWindowNumber = windowNumber
        self.targetLocation = location
        self.wheelDeltaX = deltaX
        self.wheelDeltaY = deltaY
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override var type: NSEvent.EventType { .scrollWheel }
    override var windowNumber: Int { targetWindowNumber }
    override var locationInWindow: NSPoint { targetLocation }
    override var scrollingDeltaX: CGFloat { wheelDeltaX }
    override var scrollingDeltaY: CGFloat { wheelDeltaY }
    override var hasPreciseScrollingDeltas: Bool { false }
    override var phase: NSEvent.Phase { [] }
    override var momentumPhase: NSEvent.Phase { [] }
}

private func assertNear(
    _ actual: CGFloat,
    _ expected: CGFloat,
    _ message: String,
    tolerance: CGFloat = 1
) {
    let detail = String(
        format: "%@ (actual %.2f, expected %.2f ±%.2f)",
        message,
        Double(actual),
        Double(expected),
        Double(tolerance)
    )
    let withinTolerance = abs(actual - expected) <= tolerance
    expect(withinTolerance, detail)
}

private func upwardLineWheelEvent() -> NSEvent? {
    guard let cgEvent = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .line,
        wheelCount: 1,
        wheel1: 1,
        wheel2: 0,
        wheel3: 0
    ) else { return nil }
    return NSEvent(cgEvent: cgEvent)
}

private func phaseLessPreciseWheelEvent() -> NSEvent? {
    guard let cgEvent = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 1,
        wheel1: 24,
        wheel2: 0,
        wheel3: 0
    ) else { return nil }
    return NSEvent(cgEvent: cgEvent)
}

@main
private enum AppKitTranscriptSurfaceCheck {
    static func main() {
        // The checks exercise AppKit objects without opening a window.  This
        // keeps the script deterministic in CI while still using the exact
        // NSScrollView/document-view path used by production.
        _ = NSApplication.shared

        // Prefix offsets, row lookup, one-row updates, and prepend all remain
        // deterministic and logarithmic at the height-index seam.
        var index = TranscriptHeightIndex(heights: [20, 30, 40])
        expect(index.count == 3, "height index stores all rows")
        assertNear(index.totalHeight, 90, "height index total height")
        assertNear(index.offset(of: 2), 50, "height index cumulative offset")
        expect(index.row(atOffset: 0) == 0, "row lookup clamps to first row")
        expect(index.row(atOffset: 51) == 2, "row lookup finds the containing row")
        expect(index.row(atOffset: 10_000) == 2, "row lookup clamps to last row")
        assertNear(index.update(index: 1, height: 45), 15, "single-row update returns its delta")
        assertNear(index.totalHeight, 105, "single-row update changes cumulative height")
        index.prepend([10, 11])
        expect(index.count == 5, "prepend extends the index")
        assertNear(index.offset(of: 2), 21, "prepend preserves new prefix offsets")

        let session = TranscriptSessionHandle(sessionID: "appkit-check", generation: 1, revision: 0)
        let rows = (0..<4_000).map { index in
            row(
                "row-" + String(index),
                height: 30 + CGFloat(index % 3),
                completed: index == 3_999 ? false : true
            )
        }
        let initial = TranscriptSurfaceSnapshot(session: session, rows: rows, followsLatest: false)
        let adapter = AppKitTranscriptSurfaceAdapter(
            snapshot: initial,
            overscan: 40,
            maximumMountedRows: 18,
            maximumReusableHosts: 24
        )
        expect(
            !adapter.scrollView.hasVerticalScroller,
            "the transcript keeps its historical hidden-scroll-indicator appearance"
        )
        adapter.setViewportSize(NSSize(width: 480, height: 120))
        adapter.setContentOffset(y: 300)

        expect(adapter.mountedRowIDs.count <= 18, "mounted rows stay within the bounded pool")
        expect(!adapter.mountedRowIDs.contains("row-239"), "offscreen rows are not mounted")
        expect(adapter.metrics.mountedPeak <= 18, "mounted peak respects the configured bound")
        expect(adapter.visibleRowIDs.count < 18, "visible row lookup stays independent of long-session row count")

        // A newly mounted rich host can report an intrinsic height larger than
        // its producer estimate. The first visible mount must commit that
        // height before the row is painted; otherwise the following row is
        // drawn on top of the overflowing content (the reported regression).
        let firstMountRow = row("first-mount", height: 24, text: "short estimate")
        let firstMountAdapter = AppKitTranscriptSurfaceAdapter(
            snapshot: TranscriptSurfaceSnapshot(
                session: session,
                rows: [],
                followsLatest: false
            ),
            overscan: 0,
            maximumMountedRows: 1,
            maximumReusableHosts: 0,
            renderer: { row, key in
                FirstMountMeasurementHost(row: row, key: key, measuredHeight: 220)
            }
        )
        firstMountAdapter.setViewportSize(NSSize(width: 480, height: 120))
        _ = firstMountAdapter.apply(.replace(snapshot: TranscriptSurfaceSnapshot(
            session: session,
            rows: [firstMountRow],
            followsLatest: false
        )))
        expect(
            firstMountAdapter.currentHeightIndex.height(at: 0) == 220,
            "new visible host commits its intrinsic height before painting"
        )
        expect(
            firstMountAdapter.contentHeightMismatchDiagnostics.count == 0,
            "new visible host cannot draw outside its indexed frame"
        )

        let restoredRows = [
            row("restored-tool", height: 24, text: "historical tool"),
            row("restored-answer", height: 24, text: "historical answer")
        ]
        let restoredAdapter = AppKitTranscriptSurfaceAdapter(
            snapshot: TranscriptSurfaceSnapshot(session: session, rows: [], followsLatest: false),
            overscan: 0,
            maximumMountedRows: 2,
            maximumReusableHosts: 0,
            renderer: { row, key in
                RestoredSessionMeasurementHost(row: row, key: key, settledHeight: 96)
            }
        )
        restoredAdapter.setViewportSize(NSSize(width: 480, height: 120))
        _ = restoredAdapter.apply(.replace(snapshot: TranscriptSurfaceSnapshot(
            session: session,
            rows: restoredRows,
            followsLatest: false
        )))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        expect(
            restoredAdapter.currentHeightIndex.height(at: 0) == 96
                && restoredAdapter.currentHeightIndex.height(at: 1) == 96,
            "restored historical tool and answer rows remeasure after SwiftUI settles"
        )
        expect(
            restoredAdapter.contentHeightMismatchDiagnostics.count == 0,
            "restored historical rows cannot remain clipped after the first fitting pass"
        )

        let overscanRows = [
            row("overscan-leading", height: 300),
            row("overscan-entering", height: 24, text: "underestimated rich row")
        ]
        let overscanAdapter = AppKitTranscriptSurfaceAdapter(
            snapshot: TranscriptSurfaceSnapshot(
                session: session,
                rows: overscanRows,
                followsLatest: false
            ),
            overscan: 400,
            maximumMountedRows: 2,
            maximumReusableHosts: 0,
            renderer: { row, key in
                FirstMountMeasurementHost(
                    row: row,
                    key: key,
                    measuredHeight: row.id == "overscan-entering" ? 220 : row.estimatedHeight
                )
            }
        )
        overscanAdapter.setViewportSize(NSSize(width: 480, height: 120))
        expect(
            overscanAdapter.currentHeightIndex.height(at: 1) == 24,
            "offscreen overscan host keeps its estimate until it becomes visible"
        )
        overscanAdapter.setContentOffset(y: 204)
        expect(
            overscanAdapter.currentHeightIndex.height(at: 1) == 220,
            "dirty overscan host is measured synchronously when it enters the viewport"
        )
        expect(
            overscanAdapter.contentHeightMismatchDiagnostics.count == 0,
            "overscan host cannot overlap after entering the viewport"
        )

        let shrinkingRows = [
            row("shrinking-leading", height: 600),
            row("revealed-after-shrink", height: 80)
        ]
        let shrinkingAdapter = AppKitTranscriptSurfaceAdapter(
            snapshot: TranscriptSurfaceSnapshot(
                session: session,
                rows: shrinkingRows,
                followsLatest: false
            ),
            overscan: 0,
            maximumMountedRows: 2,
            maximumReusableHosts: 0,
            renderer: { row, key in
                FirstMountMeasurementHost(
                    row: row,
                    key: key,
                    measuredHeight: row.id == "shrinking-leading" ? 100 : row.estimatedHeight,
                    requiresImmediateMeasurement: row.id == "shrinking-leading"
                )
            }
        )
        shrinkingAdapter.setViewportSize(NSSize(width: 480, height: 120))
        expect(
            shrinkingAdapter.currentHeightIndex.height(at: 0) == 100,
            "visible overestimate shrinks to its measured height"
        )
        expect(
            shrinkingAdapter.mountedRowIDs.contains("revealed-after-shrink"),
            "height shrink converges and mounts the newly exposed bottom row"
        )
        expect(
            !shrinkingAdapter.visibleMountedRowIDs.isEmpty,
            "height shrink leaves the viewport physically covered"
        )

        guard let stableID = adapter.mountedRowIDs.dropFirst(adapter.mountedRowIDs.count / 2).first,
              let stableHost = adapter.hostObjectID(rowID: stableID) else {
            failures.append("initial viewport mounts at least one row")
            finish()
            return
        }

        // A pure viewport move never reconfigures a stable rich host.
        let stableConfigureCount = adapter.hostConfigureCount(rowID: stableID) ?? -1
        adapter.setContentOffset(y: 312)
        expect(
            adapter.hostConfigureCount(rowID: stableID) == stableConfigureCount,
            "pure viewport scrolling does not reconfigure a stable row host"
        )

        // Leaving and re-entering a viewport should recover the exact
        // immutable host from the bounded identity cache. Reusing the old
        // rich tree avoids a second root transaction when a user reverses a
        // wheel gesture over the same rows.
        let cachedHost = adapter.hostObjectID(rowID: stableID)
        let cachedConfigureCount = adapter.hostConfigureCount(rowID: stableID) ?? -1
        adapter.setContentOffset(y: 8_000)
        expect(adapter.hostObjectID(rowID: stableID) == nil, "offscreen row leaves the mounted window")
        expect(
            Set(adapter.mountedRowIDs) == Set(adapter.visibleRowIDs),
            "viewport move mounts visible rows synchronously without overscan work"
        )
        adapter.setContentOffset(y: 312)
        expect(adapter.hostObjectID(rowID: stableID) == cachedHost, "returning row reuses its identity-matched host")
        expect(
            adapter.hostConfigureCount(rowID: stableID) == cachedConfigureCount,
            "identity-matched host does not reconfigure on viewport reversal"
        )

        // Overscan is refilled asynchronously and in bounded slices; the
        // synchronous viewport path only mounts rows that are needed for
        // visible correctness. The metrics keep those two costs distinct so
        // a display-linked regression cannot hide in a pooled refill.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.18))
        expect(adapter.metrics.synchronousViewportLayoutCount > 0, "synchronous viewport work is measured")
        expect(adapter.metrics.maximumSynchronousViewportDuration >= 0, "synchronous viewport duration is finite")
        expect(adapter.metrics.deferredOverscanRefillCount > 0, "deferred overscan refill is measured")
        expect(adapter.metrics.maximumDeferredOverscanRefillDuration >= 0, "deferred overscan duration is finite")
        expect(adapter.metrics.maximumDeferredOverscanRefillMounts <= 4, "deferred overscan mounts stay time-sliced")
        expect(adapter.reusableHostCount <= 24, "identity host cache stays within its configured bound")

        // A physical user-scroll handoff is synchronous, before AppKit applies
        // the wheel delta, and detaches follow-latest without consuming a
        // transcript revision.
        var sawUserScroll = false
        var userScrollCallbacks = 0
        var userScrollSequenceStarts = 0
        adapter.onViewportChanged = { _, userDriven in
            if userDriven {
                sawUserScroll = true
                userScrollCallbacks += 1
            }
        }
        adapter.onUserScrollSequenceStarted = {
            userScrollSequenceStarts += 1
        }
        adapter.userDidScroll()
        adapter.userDidScroll()
        expect(sawUserScroll, "user-scroll callback fires synchronously")
        expect(!adapter.snapshot.followsLatest, "user scroll detaches follow-latest")
        expect(userScrollSequenceStarts == 1, "closely spaced wheel packets share one scroll sequence")
        let refillsBeforeActiveScroll = adapter.metrics.deferredOverscanRefillCount
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        expect(
            adapter.metrics.deferredOverscanRefillCount == refillsBeforeActiveScroll,
            "active user scrolling defers overscan refill work"
        )
        let userScrollCountBeforeResize = userScrollCallbacks
        adapter.setViewportSize(NSSize(width: 480, height: 120))
        expect(userScrollCallbacks == userScrollCountBeforeResize, "resize does not masquerade as user scroll")

        // A replacement with stable row identities updates hosts in place.
        let revisionOne = adapter.currentHandle.nextRevision()
        let stableReplacement = adapter.apply(
            .replace(
                snapshot: TranscriptSurfaceSnapshot(
                    session: revisionOne,
                    rows: rows,
                    followsLatest: false
                )
            )
        )
        expect(
            stableReplacement.contains {
                if case let .snapshotApplied(_, reused, invalidated, _) = $0 {
                    return reused.count == rows.count && invalidated.isEmpty
                }
                return false
            },
            "stable content identities are reported as reused"
        )
        assertNear(
            CGFloat(adapter.hostObjectID(rowID: stableID) == stableHost ? 1 : 0),
            1,
            "stable visible row host is reused",
            tolerance: 0
        )

        // A streamed tail update keeps the row sequence stable and updates
        // one Fenwick point instead of rebuilding all 4,000 prefixes.
        let rebuildsBeforeTail = adapter.metrics.heightIndexRebuilds
        let pointUpdatesBeforeTail = adapter.metrics.heightIndexPointUpdates
        var tailRows = rows
        tailRows[tailRows.count - 1] = row("row-3999", version: 2, height: 96, completed: false)
        let tailRevision = adapter.currentHandle.nextRevision()
        let tailEvents = adapter.apply(
            .replace(
                snapshot: TranscriptSurfaceSnapshot(
                    session: tailRevision,
                    rows: tailRows,
                    followsLatest: false
                )
            )
        )
        expect(
            tailEvents.contains {
                if case let .snapshotApplied(_, _, invalidated, _) = $0 {
                    return invalidated == ["row-3999"]
                }
                return false
            },
            "tail replacement invalidates only the streamed row"
        )
        expect(
            adapter.metrics.heightIndexRebuilds == rebuildsBeforeTail,
            "streaming tail replacement does not rebuild the height index"
        )
        expect(
            adapter.metrics.heightIndexPointUpdates > pointUpdatesBeforeTail,
            "streaming tail replacement performs a logarithmic point update"
        )

        // Exercise the actual full-snapshot bridge used by SwiftUI while only
        // the live tail changes. Stable history must stay comfortably inside
        // one 60 Hz frame even with 4,000 immutable rows present.
        var streamingDurations: [Double] = []
        streamingDurations.reserveCapacity(80)
        for version in 3..<83 {
            let streamedTail = row(
                "row-3999",
                version: UInt64(version),
                height: 96 + CGFloat(version % 2),
                completed: false
            )
            let started = ProcessInfo.processInfo.systemUptime
            _ = adapter.apply(.update(row: streamedTail, session: adapter.currentHandle.nextRevision()))
            streamingDurations.append(
                (ProcessInfo.processInfo.systemUptime - started) * 1_000
            )
        }
        let sortedStreamingDurations = streamingDurations.sorted()
        streamingTailP95MS = sortedStreamingDurations[
            min(sortedStreamingDurations.count - 1, Int(Double(sortedStreamingDurations.count) * 0.95))
        ]
        expect(
            streamingTailP95MS <= 17,
            "4,000-row streaming tail p95 stays within one 60 Hz frame"
        )

        // The production Overlay sends an index-addressed update for each
        // token. Exercise that exact command shape (rather than a full
        // replace snapshot) and assert the adapter's inspected-row counter.
        let directUpdatesBefore = adapter.metrics.rowUpdateCount
        let directInspectedBefore = adapter.metrics.rowUpdateInspectedRows
        for version in 83..<103 {
            _ = adapter.apply(.update(
                row: row(
                    "row-3999",
                    version: UInt64(version),
                    height: 96 + CGFloat(version % 2),
                    completed: false
                ),
                session: adapter.currentHandle.nextRevision()
            ))
        }
        expect(
            adapter.metrics.rowUpdateCount - directUpdatesBefore == 20,
            "index-addressed streaming updates are counted"
        )
        expect(
            adapter.metrics.rowUpdateInspectedRows - directInspectedBefore == 20,
            "index-addressed streaming updates inspect one row each"
        )

        // The post-wheel callback reports the actual end state after a user
        // delta, allowing the follow policy to resume when the wheel reaches
        // the tail.
        var lastUserAtEnd = false
        adapter.onViewportChanged = { atEnd, userDriven in
            if userDriven { lastUserAtEnd = atEnd }
        }
        adapter.setContentOffset(y: adapter.currentHeightIndex.totalHeight)
        adapter.userScrollDidApply()
        expect(lastUserAtEnd, "post-wheel callback reports actual viewport state")
        adapter.setContentOffset(y: 312)

        // Typography/geometry/layout revisions are independent of immutable
        // prose content.  They must still refresh a mounted host and select a
        // different height-cache key.
        let beforeLayoutHost = adapter.hostObjectID(rowID: stableID)
        let beforeLayoutConfigure = adapter.hostConfigureCount(rowID: stableID) ?? 0
        let layoutRows = adapter.snapshot.rows.map { existing -> TranscriptRowSnapshot in
            guard existing.id == stableID else { return existing }
            return TranscriptRowSnapshot(
                id: existing.id,
                contentVersion: existing.contentVersion,
                contentHash: existing.contentHash,
                estimatedHeight: existing.estimatedHeight,
                isCompleted: existing.isCompleted,
                kind: existing.kind,
                text: existing.text,
                typography: TranscriptTypographyKey(
                    fontFamily: ".AppleSystemUIFont",
                    pointSize: 15,
                    weight: 400,
                    lineHeight: 1.625,
                    styleID: "appkit-check-layout"
                ),
                geometry: existing.geometry,
                layoutVersion: existing.layoutVersion + 1
            )
        }
        _ = adapter.apply(.replace(snapshot: TranscriptSurfaceSnapshot(
            session: adapter.currentHandle.nextRevision(),
            rows: layoutRows
        )))
        expect(
            adapter.hostObjectID(rowID: stableID) != beforeLayoutHost
                || (adapter.hostConfigureCount(rowID: stableID) ?? 0) > beforeLayoutConfigure,
            "layout-only row change refreshes the mounted host"
        )
        if let existing = adapter.snapshot.row(id: stableID) {
            let layoutOnlyUpdate = TranscriptRowSnapshot(
                id: existing.id,
                contentVersion: existing.contentVersion,
                contentHash: existing.contentHash,
                estimatedHeight: existing.estimatedHeight + 2,
                isCompleted: existing.isCompleted,
                kind: existing.kind,
                text: existing.text,
                historyTickID: existing.historyTickID,
                typography: existing.typography,
                geometry: TranscriptLocalGeometryState(
                    isExpanded: !existing.geometry.isExpanded,
                    accessorySignature: existing.geometry.accessorySignature
                ),
                layoutVersion: existing.layoutVersion + 1
            )
            _ = adapter.apply(.update(
                row: layoutOnlyUpdate,
                session: adapter.currentHandle.nextRevision()
            ))
            expect(
                adapter.snapshot.row(id: stableID)?.layoutIdentity == layoutOnlyUpdate.layoutIdentity,
                "direct row update persists layout-only changes"
            )
        }

        // A workspace card has no transcript text; its running/done state is
        // represented by producer metadata and therefore only changes the
        // row content identity. Start with a genuinely mutable row—the exact
        // production contract—then verify its terminal update reaches the
        // mounted host instead of being rejected as completed history.
        let workspaceRowID = "workspace-card"
        let workspaceSession = TranscriptSessionHandle(
            sessionID: "workspace-transition",
            generation: 1,
            revision: 0
        )
        let workspaceAdapter = AppKitTranscriptSurfaceAdapter(
            snapshot: TranscriptSurfaceSnapshot(
                session: workspaceSession,
                rows: [row(workspaceRowID, version: 20, height: 72, completed: false)]
            ),
            overscan: 0,
            maximumMountedRows: 1,
            maximumReusableHosts: 0
        )
        workspaceAdapter.setViewportSize(NSSize(width: 480, height: 120))
        let configureBeforeWorkspaceDone = workspaceAdapter.hostConfigureCount(
            rowID: workspaceRowID
        ) ?? 0
        _ = workspaceAdapter.apply(.update(
            row: row(workspaceRowID, version: 21, height: 72, completed: true),
            session: workspaceAdapter.currentHandle.nextRevision()
        ))
        expect(
            workspaceAdapter.snapshot.row(id: workspaceRowID)?.isCompleted == true,
            "workspace running-to-done metadata reaches the adapter snapshot"
        )
        expect(
            (workspaceAdapter.hostConfigureCount(rowID: workspaceRowID) ?? 0)
                > configureBeforeWorkspaceDone,
            "workspace running-to-done metadata reconfigures its mounted host"
        )

        // Line-based mouse wheels bypass AppKit's delayed smoothing and move
        // the production viewport in the same event. Trackpads still carry
        // precise deltas and remain on AppKit's native momentum path.
        let discreteWheelMaximumY = max(
            0,
            adapter.currentHeightIndex.totalHeight - adapter.scrollView.contentView.bounds.height
        )
        adapter.setContentOffset(y: discreteWheelMaximumY / 2)
        if let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: -1,
            wheel2: 0,
            wheel3: 0
        ), let wheelEvent = NSEvent(cgEvent: cgEvent) {
            let beforeDiscreteWheel = adapter.contentOffsetY
            adapter.scrollView.scrollWheel(with: wheelEvent)
            expect(
                abs(adapter.contentOffsetY - beforeDiscreteWheel) > 0.5,
                "discrete mouse wheel moves synchronously"
            )
        } else {
            failures.append("synthetic discrete mouse wheel event is available")
        }

        // Updating one visible row remounts at most that row.  Unrelated
        // visible hosts retain their object identity.
        let otherID = adapter.mountedRowIDs.first { $0 != stableID }
        let otherHost = otherID.flatMap { adapter.hostObjectID(rowID: $0) }
        let beforeMounts = adapter.metrics.totalMounts
        let revisionTwo = adapter.currentHandle.nextRevision()
        let changed = row(stableID, version: 2, height: 96)
        _ = adapter.apply(.update(row: changed, session: revisionTwo))
        let remounts = adapter.metrics.totalMounts - beforeMounts
        expect(remounts <= 1, "one row update mounts at most one host")
        expect(adapter.metrics.rowUpdateCount > 0, "streaming row update uses the direct adapter path")
        expect(adapter.metrics.rowUpdateInspectedRows == adapter.metrics.rowUpdateCount, "streaming row updates inspect exactly one row each")
        if let otherID, let otherHost {
            expect(adapter.hostObjectID(rowID: otherID) == otherHost, "unrelated row host remains mounted")
        }

        // Height changes before the visible anchor preserve the anchor's
        // document-to-viewport position to within one point.
        adapter.setContentOffset(y: 900)
        guard let anchor = adapter.currentVisibleAnchor() else {
            failures.append("visible anchor is available after scrolling")
            finish()
            return
        }
        let anchorIndex = rows.firstIndex { $0.id == anchor.rowID } ?? 0
        let beforeOffset = adapter.contentOffsetY
        let heightTarget = rows[max(0, anchorIndex - 1)].id
        _ = adapter.updateMeasuredHeight(rowID: heightTarget, height: 80)
        let afterAnchor = adapter.currentVisibleAnchor()
        expect(afterAnchor?.rowID == anchor.rowID, "height update retains the visible anchor row")
        if let afterAnchor {
            assertNear(afterAnchor.offset, anchor.offset, "height update retains anchor offset")
        }
        expect(adapter.contentOffsetY > beforeOffset, "height update shifts the clip origin by the preceding delta")

        // When following the tail, a newly measured row keeps the viewport at
        // the new end instead of restoring the old visible anchor.
        adapter.setFollowLatest(true)
        let followTarget = rows[rows.count - 1].id
        let previousEnd = adapter.contentOffsetY
        _ = adapter.updateMeasuredHeight(rowID: followTarget, height: 120)
        let expectedEnd = max(0, adapter.currentHeightIndex.totalHeight - adapter.scrollView.contentView.bounds.height)
        assertNear(adapter.contentOffsetY, expectedEnd, "follow-latest measurement remains pinned to end")
        expect(adapter.contentOffsetY >= previousEnd, "follow-latest measurement does not move backwards")

        // Width is a layout input: sub-pixel motion inside a half-point bucket
        // keeps measurements, while crossing the bucket restores estimates.
        let measuredID = rows[0].id
        _ = adapter.updateMeasuredHeight(rowID: measuredID, height: 144)
        let measuredHeight = adapter.currentHeightIndex.height(at: 0) ?? 0
        adapter.setViewportSize(NSSize(width: 480.2, height: 120))
        expect(adapter.currentHeightIndex.height(at: 0) == measuredHeight, "same width bucket retains measured height")
        adapter.setViewportSize(NSSize(width: 480.8, height: 120))
        expect(adapter.currentHeightIndex.height(at: 0) != measuredHeight, "width bucket change invalidates measured heights")
        adapter.setViewportSize(NSSize(width: 480.2, height: 120))
        expect(adapter.currentHeightIndex.height(at: 0) == measuredHeight, "returning to a width bucket restores its cached height")

        // A stale revision is ignored before it can affect mounted cells.
        let staleHost = adapter.hostObjectID(rowID: stableID)
        let staleEvents = adapter.apply(.update(row: row(stableID, version: 99, height: 120), session: revisionTwo))
        expect(staleEvents.contains { if case .staleRevisionIgnored = $0 { return true }; return false }, "stale revision is rejected")
        expect(adapter.hostObjectID(rowID: stableID) == staleHost, "stale revision does not remount a row")

        // Viewport commands are immediate and do not require a revision.
        let endEvents = adapter.perform(.scrollToEnd(session: adapter.currentHandle.nextRevision(), animated: true))
        expect(endEvents.contains { if case .scrollToEndRequested = $0 { return true }; return false }, "scroll-to-end command emits its event")
        assertNear(
            adapter.contentOffsetY,
            max(0, adapter.currentHeightIndex.totalHeight - adapter.scrollView.contentView.bounds.height),
            "scroll-to-end reaches the document end"
        )
        if let wheelAwayFromEnd = upwardLineWheelEvent() {
            let endBeforeWheel = adapter.contentOffsetY
            expect(
                wheelAwayFromEnd.scrollingDeltaY > 0,
                "synthetic end-detach wheel uses the upward physical direction"
            )
            adapter.scrollView.scrollWheel(with: wheelAwayFromEnd)
            expect(
                adapter.contentOffsetY < endBeforeWheel - 0.5,
                "a discrete mouse wheel detaches and moves immediately from the transcript end"
            )
            expect(
                !adapter.snapshot.followsLatest,
                "a discrete mouse wheel leaves follow-latest after moving from the end"
            )
        } else {
            failures.append("synthetic end-detach mouse wheel event is available")
        }
        _ = adapter.perform(.reveal(rowID: "row-0", session: adapter.currentHandle.nextRevision()))
        expect(adapter.contentOffsetY <= 1, "reveal brings the requested row into view")
        _ = adapter.perform(.setFollowLatest(false, session: adapter.currentHandle.nextRevision()))
        expect(!adapter.snapshot.followsLatest, "set-follow command updates follow state")
        _ = adapter.perform(.invalidate(rowIDs: [stableID], session: adapter.currentHandle.nextRevision()))
        expect(adapter.metrics.layoutCount > 0, "local invalidation triggers a bounded layout pass")

        // Exercise the window/location capture seam used before AppKit hit
        // testing reaches nested SwiftUI horizontal scroll views.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = adapter.scrollView
        window.makeKeyAndOrderFront(nil)

        // A nonactivating panel can receive a windowless wheel packet at the
        // focus boundary. Its location is in screen coordinates and must be
        // routed to the visible transcript instead of discarded.
        let otherWindow = NSWindow(
            contentRect: NSRect(x: 500, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let handlerGeneration = adapter.scrollView.localWheelHandlerGeneration
        var focusCyclesMoved = 0
        for _ in 0..<20 {
            otherWindow.makeKeyAndOrderFront(nil)
            window.makeKeyAndOrderFront(nil)
            adapter.setContentOffset(y: max(
                0,
                adapter.currentHeightIndex.totalHeight - adapter.scrollView.contentView.bounds.height
            ))
            let endBeforeRoutedWheel = adapter.contentOffsetY
            NSApp.sendEvent(WindowRoutedWheelEvent(
                windowNumber: 0,
                location: window.convertPoint(toScreen: NSPoint(x: 240, y: 60)),
                deltaY: 1
            ))
            if adapter.contentOffsetY < endBeforeRoutedWheel - 0.5 {
                focusCyclesMoved += 1
            }
        }
        expect(
            focusCyclesMoved == 20,
            "every refocused windowless wheel immediately leaves the transcript end"
        )
        expect(
            adapter.scrollView.localWheelHandlerGeneration == handlerGeneration + 20,
            "each refocused wheel receives exactly one local-monitor pass"
        )
        let generationBeforeOutsideWheel = adapter.scrollView.localWheelHandlerGeneration
        NSApp.sendEvent(WindowRoutedWheelEvent(
            windowNumber: 0,
            location: NSPoint(x: -10_000, y: -10_000),
            deltaY: 1
        ))
        expect(
            adapter.scrollView.localWheelHandlerGeneration == generationBeforeOutsideWheel,
            "a windowless wheel outside Bubble is not captured"
        )
        expect(
            adapter.scrollView.lastLocalWheelHandlerDuration >= 0,
            "the production local monitor reports finite app-owned work"
        )

        // A precise mouse packet without AppKit phase metadata is applied by
        // NSScrollView asynchronously. The immediate post-super callback must
        // not report that the user is still at the end and re-arm following
        // before the native bounds transaction commits.
        if let preciseWheel = phaseLessPreciseWheelEvent() {
            adapter.scrollToEnd()
            var phaseLessReports: [Bool] = []
            adapter.onViewportChanged = { atEnd, userDriven in
                if userDriven { phaseLessReports.append(atEnd) }
            }
            adapter.userDidScroll(event: preciseWheel)
            adapter.userScrollDidApply()
            expect(
                phaseLessReports == [false],
                "phase-less precise wheel stays detached until native bounds commit"
            )
            let tailOffset = adapter.contentOffsetY
            adapter.setContentOffset(y: max(0, tailOffset - 24))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            expect(
                phaseLessReports == [false, false],
                "the native bounds commit completes the phase-less wheel as detached"
            )
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.14))
            expect(
                phaseLessReports == [false, false],
                "the cancelled phase-less fallback cannot re-arm following"
            )

            adapter.scrollToEnd()
            phaseLessReports.removeAll()
            adapter.userDidScroll(event: preciseWheel)
            adapter.userScrollDidApply()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.14))
            expect(
                phaseLessReports == [false, true],
                "a phase-less boundary packet settles back to the tail when bounds never move"
            )
        } else {
            failures.append("phase-less precise wheel fixture is available")
        }

        finish()
    }

    private static func finish() {
        if failures.isEmpty {
            print(String(
                format: "PASS: AppKit transcript surface height index, reuse, mount window, anchor, stale, commands, and streamingTailP95=%.2fms",
                streamingTailP95MS
            ))
        } else {
            for failure in failures {
                FileHandle.standardError.write(Data(("FAIL: " + failure + "\n").utf8))
            }
            exit(1)
        }
    }
}
