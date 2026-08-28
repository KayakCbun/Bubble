import AppKit
import Foundation

private var failures: [String] = []

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}

private func row(
    _ id: String,
    version: UInt64 = 1,
    height: CGFloat = 32,
    text: String? = nil
) -> TranscriptRowSnapshot {
    TranscriptRowSnapshot(
        id: id,
        contentVersion: version,
        contentHash: id + "-" + String(version),
        estimatedHeight: height,
        kind: .assistant,
        text: text
    )
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
        let rows = (0..<240).map { row("row-" + String($0), height: 30 + CGFloat($0 % 3)) }
        let initial = TranscriptSurfaceSnapshot(session: session, rows: rows, followsLatest: false)
        let adapter = AppKitTranscriptSurfaceAdapter(
            snapshot: initial,
            overscan: 40,
            maximumMountedRows: 18,
            maximumReusableHosts: 24
        )
        adapter.setViewportSize(NSSize(width: 480, height: 120))
        adapter.setContentOffset(y: 300)

        expect(adapter.mountedRowIDs.count <= 18, "mounted rows stay within the bounded pool")
        expect(!adapter.mountedRowIDs.contains("row-239"), "offscreen rows are not mounted")
        expect(adapter.metrics.mountedPeak <= 18, "mounted peak respects the configured bound")

        guard let stableID = adapter.mountedRowIDs.first,
              let stableHost = adapter.hostObjectID(rowID: stableID) else {
            failures.append("initial viewport mounts at least one row")
            finish()
            return
        }

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
        _ = adapter.perform(.reveal(rowID: "row-0", session: adapter.currentHandle.nextRevision()))
        expect(adapter.contentOffsetY <= 1, "reveal brings the requested row into view")
        _ = adapter.perform(.setFollowLatest(false, session: adapter.currentHandle.nextRevision()))
        expect(!adapter.snapshot.followsLatest, "set-follow command updates follow state")
        _ = adapter.perform(.invalidate(rowIDs: [stableID], session: adapter.currentHandle.nextRevision()))
        expect(adapter.metrics.layoutCount > 0, "local invalidation triggers a bounded layout pass")

        finish()
    }

    private static func finish() {
        if failures.isEmpty {
            print("PASS: AppKit transcript surface height index, reuse, mount window, anchor, stale, and command invariants")
        } else {
            for failure in failures {
                FileHandle.standardError.write(Data(("FAIL: " + failure + "\n").utf8))
            }
            exit(1)
        }
    }
}
