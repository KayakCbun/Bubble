import AppKit
import Foundation

/// A small, deterministic identity for an AppKit row host.  The content hash
/// is deliberately not part of this key: contentVersion is the producer's
/// explicit invalidation boundary and lets hosts be reused without comparing
/// large message bodies on every layout pass.
struct AppKitTranscriptRowReuseKey: Equatable, Hashable {
    let kind: TranscriptRowKind
    let id: String
    let contentVersion: UInt64

    init(kind: TranscriptRowKind, id: String, contentVersion: UInt64) {
        self.kind = kind
        self.id = id
        self.contentVersion = contentVersion
    }

    init(row: TranscriptRowSnapshot) {
        self.init(kind: row.kind, id: row.id, contentVersion: row.contentVersion)
    }
}

/// The renderer seam for the AppKit transcript surface.  Bubble's current
/// rich SwiftUI rows remain private to OverlayView; a later extraction can
/// provide a factory that embeds those rows in an NSHostingView without
/// changing the surface, height index, or reuse policy.
typealias AppKitTranscriptRowHostFactory = (
    _ row: TranscriptRowSnapshot,
    _ key: AppKitTranscriptRowReuseKey
) -> AppKitTranscriptRowHost

/// A production-safe fallback host.  It intentionally renders plain text so
/// this surface can ship independently of the private rich row renderer.  A
/// renderer factory may subclass this host or install an NSHostingView-backed
/// content view when the semantic row extraction is ready.
class AppKitTranscriptRowHost: NSView {
    private let fallbackLabel = NSTextField(labelWithString: "")
    private(set) var row: TranscriptRowSnapshot
    private(set) var reuseKey: AppKitTranscriptRowReuseKey
    private(set) var configureCount = 0

    init(row: TranscriptRowSnapshot, key: AppKitTranscriptRowReuseKey) {
        self.row = row
        self.reuseKey = key
        super.init(frame: .zero)
        wantsLayer = true
        fallbackLabel.font = NSFont.systemFont(ofSize: 14)
        fallbackLabel.lineBreakMode = .byWordWrapping
        fallbackLabel.maximumNumberOfLines = 0
        fallbackLabel.translatesAutoresizingMaskIntoConstraints = true
        addSubview(fallbackLabel)
        configure(row: row, key: key)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Updates the host in place.  The surface only calls this when the
    /// identity is unchanged, or immediately after a pooled host is assigned
    /// a new row; no SwiftUI tree-wide state is involved.
    func configure(row: TranscriptRowSnapshot, key: AppKitTranscriptRowReuseKey) {
        self.row = row
        self.reuseKey = key
        configureCount += 1
        fallbackLabel.stringValue = row.text ?? ""
        fallbackLabel.isHidden = (row.text ?? "").isEmpty
        needsLayout = true
    }

    /// Hook for pooled subclasses to clear transient state before reuse.
    override func prepareForReuse() {}

    override func layout() {
        super.layout()
        fallbackLabel.frame = bounds.insetBy(dx: 12, dy: 8)
    }

    override var intrinsicContentSize: NSSize {
        let fitting = fallbackLabel.intrinsicContentSize
        guard !fallbackLabel.isHidden else { return NSSize(width: NSView.noIntrinsicMetric, height: 0) }
        return NSSize(width: NSView.noIntrinsicMetric, height: max(1, fitting.height + 16))
    }
}

/// A Fenwick-backed height index.  Prefix offsets and row lookup stay
/// logarithmic while one-row measurement updates avoid rebuilding the
/// transcript.  The index stores a minimum one-point height for zero/invalid
/// estimates so an offscreen row can never collapse its lookup interval.
struct TranscriptHeightIndex {
    private(set) var heights: [CGFloat]
    private var tree: [CGFloat]

    init(heights: [CGFloat] = [], minimumHeight: CGFloat = 1) {
        self.heights = heights.map { Self.normalize($0, minimum: minimumHeight) }
        self.tree = Array(repeating: 0, count: heights.count + 1)
        rebuildTree()
    }

    var count: Int { heights.count }
    var totalHeight: CGFloat { prefixSum(count) }

    func height(at index: Int) -> CGFloat? {
        guard heights.indices.contains(index) else { return nil }
        return heights[index]
    }

    /// Y offset of the row's top edge in the flipped document view.
    func offset(of index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        return prefixSum(min(index, count))
    }

    /// Prefix height before `index`; aliases offset(of:) for callers that use
    /// cumulative terminology.
    func cumulativeOffset(before index: Int) -> CGFloat {
        offset(of: index)
    }

    /// Returns the row containing a document-space Y coordinate.  Coordinates
    /// outside the document clamp to the first/last row, which makes a direct
    /// wheel event deterministic even while the viewport is settling.
    func row(atOffset rawOffset: CGFloat) -> Int? {
        guard !heights.isEmpty else { return nil }
        let target = min(max(0, rawOffset.isFinite ? rawOffset : 0), totalHeight)
        var low = 0
        var high = count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if offset(of: middle) <= target {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// Index of the first row intersecting the given range, and the exclusive
    /// end row.  Overscan is expressed in document points, not row counts.
    func rows(
        intersecting origin: CGFloat,
        viewportHeight: CGFloat,
        overscan: CGFloat
    ) -> Range<Int> {
        guard !heights.isEmpty else { return 0..<0 }
        let start = max(0, origin - max(0, overscan))
        let end = min(totalHeight, origin + max(0, viewportHeight) + max(0, overscan))
        let first = row(atOffset: start) ?? 0
        let last = row(atOffset: end) ?? first
        return first..<min(count, last + 1)
    }

    /// Updates one measured row and returns the delta applied to the document.
    @discardableResult
    mutating func update(index: Int, height: CGFloat, minimumHeight: CGFloat = 1) -> CGFloat {
        guard heights.indices.contains(index) else { return 0 }
        let next = Self.normalize(height, minimum: minimumHeight)
        let delta = next - heights[index]
        guard delta != 0 else { return 0 }
        heights[index] = next
        add(delta, at: index + 1)
        return delta
    }

    mutating func append(_ values: [CGFloat], minimumHeight: CGFloat = 1) {
        guard !values.isEmpty else { return }
        heights.append(contentsOf: values.map { Self.normalize($0, minimum: minimumHeight) })
        tree = Array(repeating: 0, count: heights.count + 1)
        rebuildTree()
    }

    /// Prepends rows while retaining the existing row order.  The caller can
    /// capture an anchor before this operation and restore it by row ID after
    /// the document frame is updated.
    mutating func prepend(_ values: [CGFloat], minimumHeight: CGFloat = 1) {
        guard !values.isEmpty else { return }
        heights = values.map { Self.normalize($0, minimum: minimumHeight) } + heights
        tree = Array(repeating: 0, count: heights.count + 1)
        rebuildTree()
    }

    mutating func replace(with values: [CGFloat], minimumHeight: CGFloat = 1) {
        heights = values.map { Self.normalize($0, minimum: minimumHeight) }
        tree = Array(repeating: 0, count: heights.count + 1)
        rebuildTree()
    }

    private static func normalize(_ value: CGFloat, minimum: CGFloat) -> CGFloat {
        let floor = max(0.01, minimum.isFinite ? minimum : 1)
        return max(floor, value.isFinite ? value : floor)
    }

    private mutating func rebuildTree() {
        guard !heights.isEmpty else { return }
        for index in heights.indices {
            add(heights[index], at: index + 1)
        }
    }

    private func prefixSum(_ count: Int) -> CGFloat {
        var index = min(max(0, count), heights.count)
        var result: CGFloat = 0
        while index > 0 {
            result += tree[index]
            index -= index & -index
        }
        return result
    }

    private mutating func add(_ value: CGFloat, at oneBasedIndex: Int) {
        var index = oneBasedIndex
        while index < tree.count {
            tree[index] += value
            index += index & -index
        }
    }
}

/// Observable counters for focused checks and performance instrumentation.
struct AppKitTranscriptSurfaceMetrics {
    private(set) var mountedPeak = 0
    private(set) var cacheHits = 0
    private(set) var cacheMisses = 0
    private(set) var layoutCount = 0
    private(set) var lastLayoutDuration: TimeInterval = 0
    private(set) var maximumLayoutDuration: TimeInterval = 0
    private(set) var totalMounts = 0
    private(set) var totalUnmounts = 0
    private(set) var pooledReuses = 0

    mutating func recordLayout(duration: TimeInterval) {
        layoutCount += 1
        lastLayoutDuration = duration
        maximumLayoutDuration = max(maximumLayoutDuration, duration)
    }

    mutating func recordMount(count: Int, peak: Int, reused: Bool) {
        totalMounts += count
        mountedPeak = max(mountedPeak, peak)
        if reused { pooledReuses += count }
        if reused { cacheHits += count } else { cacheMisses += count }
    }

    mutating func recordUnmount(count: Int) {
        totalUnmounts += count
    }
}

/// The clip view used by the production surface.  AppKit's bounds-change
/// notification is delivered after the scroll wheel has already been
/// interpreted, which is too late for the composer/follow policy: a new wheel
/// event must detach from the tail before the next streamed token arrives.
/// Keep this hook at the physical input boundary and let the adapter decide
/// whether the event is user-driven or programmatic.
final class AppKitTranscriptScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }
}

private final class AppKitTranscriptDocumentView: NSView {
    weak var owner: AppKitTranscriptSurfaceAdapter?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        owner?.documentDidLayout()
    }
}

private final class AppKitTranscriptMountedCell {
    var key: AppKitTranscriptRowReuseKey
    let host: AppKitTranscriptRowHost

    init(key: AppKitTranscriptRowReuseKey, host: AppKitTranscriptRowHost) {
        self.key = key
        self.host = host
    }
}

/// AppKit-backed transcript surface.  It owns one flipped document view and
/// mounts only the viewport plus overscan.  The class intentionally exposes a
/// renderer factory instead of embedding Bubble's current private SwiftUI
/// rows; the latter can be wired in as a later, isolated extraction.
final class AppKitTranscriptSurfaceAdapter: NSObject, TranscriptSurfaceAdapter {
    private let state: RecordingTranscriptSurfaceAdapter
    private let rowFactory: AppKitTranscriptRowHostFactory
    private let overscan: CGFloat
    private let maximumMountedRows: Int
    private let maximumReusableHosts: Int
    private var document: AppKitTranscriptDocumentView!
    private var clipBoundsObserver: NSObjectProtocol?
    private var mounted: [String: AppKitTranscriptMountedCell] = [:]
    private var reusableHosts: [AppKitTranscriptRowHost] = []
    private var measuredHeights: [String: (identity: TranscriptRowIdentity, height: CGFloat)] = [:]
    private var heightIndex: TranscriptHeightIndex
    private var layingOut = false
    private var followsLatest = false
    private var userDetachedFromLatest = false
    private var widthBucket: Int = 0
    private(set) var metrics = AppKitTranscriptSurfaceMetrics()

    let scrollView: AppKitTranscriptScrollView
    /// Called after a viewport change.  The boolean identifies a physical
    /// user wheel event; programmatic reveal/follow operations report false.
    var onViewportChanged: ((_ atEnd: Bool, _ userDriven: Bool) -> Void)?

    init(
        snapshot: TranscriptSurfaceSnapshot? = nil,
        overscan: CGFloat = 560,
        maximumMountedRows: Int = 96,
        maximumReusableHosts: Int = 160,
        renderer: @escaping AppKitTranscriptRowHostFactory = { row, key in
            AppKitTranscriptRowHost(row: row, key: key)
        }
    ) {
        self.state = RecordingTranscriptSurfaceAdapter(snapshot: snapshot)
        self.rowFactory = renderer
        self.overscan = max(0, overscan)
        self.maximumMountedRows = max(1, maximumMountedRows)
        self.maximumReusableHosts = max(0, maximumReusableHosts)
        self.heightIndex = TranscriptHeightIndex(
            heights: (snapshot?.rows ?? []).map(\.estimatedHeight)
        )
        self.followsLatest = snapshot?.followsLatest ?? false
        self.scrollView = AppKitTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        super.init()

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.onUserScroll = { [weak self] in
            self?.userDidScroll()
        }

        document = AppKitTranscriptDocumentView(frame: .zero)
        document.owner = self
        scrollView.documentView = document
        updateDocumentFrame()
        clipBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            // This observer is synchronous with the clip-view bounds update;
            // direct mouse-wheel input therefore mounts rows without waiting
            // for a measurement pass or a display-linked animation.
            guard let self else { return }
            self.relayoutNow()
            // Bounds changes are deliberately neutral.  Window resizing,
            // elastic settling, and measurement clamps all arrive through
            // this path too; only `scrollWheel(with:)` calls userDidScroll()
            // and reports userDriven=true.
            self.onViewportChanged?(self.isAtEnd, false)
        }
        relayoutNow()
    }

    deinit {
        if let clipBoundsObserver {
            NotificationCenter.default.removeObserver(clipBoundsObserver)
        }
    }

    var snapshot: TranscriptSurfaceSnapshot {
        let source = state.snapshot
        guard source.followsLatest != followsLatest else { return source }
        return TranscriptSurfaceSnapshot(
            session: source.session,
            rows: source.rows,
            anchor: source.anchor,
            followsLatest: followsLatest
        )
    }
    var interactionStore: TranscriptInteractionStore { state.interactionStore }
    var heightCache: TranscriptHeightCache { state.heightCache }
    var currentHandle: TranscriptSessionHandle { state.currentHandle }
    var mountedRowIDs: [String] { mounted.keys.sorted() }
    var reusableHostCount: Int { reusableHosts.count }
    var currentHeightIndex: TranscriptHeightIndex { heightIndex }

    /// A cheap viewport helper used by deterministic checks and by the future
    /// NSViewRepresentable bridge.  It never waits for row measurement.
    func setViewportSize(_ size: NSSize) {
        let nextBucket = Self.widthBucket(size.width)
        if nextBucket != widthBucket {
            widthBucket = nextBucket
            measuredHeights.removeAll(keepingCapacity: true)
            // Width is part of text layout identity.  Existing measured
            // heights are invalid even when row content versions are stable.
            heightIndex.replace(with: snapshot.rows.map(\.estimatedHeight))
        }
        scrollView.setFrameSize(size)
        relayoutNow()
    }

    func setContentOffset(y: CGFloat) {
        let maxY = max(0, heightIndex.totalHeight - scrollView.contentView.bounds.height)
        let clamped = min(max(0, y), maxY)
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: clamped))
        relayoutNow()
    }

    var contentOffsetY: CGFloat { scrollView.contentView.bounds.minY }

    func hostObjectID(rowID: String) -> ObjectIdentifier? {
        mounted[rowID].map { ObjectIdentifier($0.host) }
    }

    func hostConfigureCount(rowID: String) -> Int? {
        mounted[rowID]?.host.configureCount
    }

    /// Captures the first visible row and its document-to-viewport offset.
    func currentVisibleAnchor() -> TranscriptSurfaceAnchor? {
        guard let index = heightIndex.row(atOffset: contentOffsetY),
              snapshot.rows.indices.contains(index) else { return nil }
        return TranscriptSurfaceAnchor(
            rowID: snapshot.rows[index].id,
            offset: heightIndex.offset(of: index) - contentOffsetY
        )
    }

    @discardableResult
    func updateMeasuredHeight(rowID: String, height: CGFloat) -> Bool {
        guard let index = snapshot.rows.firstIndex(where: { $0.id == rowID }) else { return false }
        let anchor = currentVisibleAnchor()
        let row = snapshot.rows[index]
        measuredHeights[rowID] = (row.contentIdentity, height)
        let changed = heightIndex.update(index: index, height: height) != 0
        guard changed else { return false }
        updateDocumentFrame()
        relayoutNow()
        // A streamed tail measurement changes document height below the
        // viewport.  Restoring the old anchor in follow mode reopens the gap
        // that the user just asked us to keep closed; pin to the end instead.
        if followsLatest {
            scrollToEnd()
        } else if let anchor {
            restore(anchor)
        }
        return true
    }

    @discardableResult
    func apply(_ command: TranscriptSurfaceCommand) -> [TranscriptSurfaceEvent] {
        let oldSnapshot = state.snapshot
        let anchor = anchorBefore(command.anchorPolicy, oldSnapshot: oldSnapshot)
        let events = state.apply(command)
        guard accepted(events) else { return events }

        if requestsFollowLatest(command.kind) {
            userDetachedFromLatest = false
        }
        followsLatest = userDetachedFromLatest ? false : state.snapshot.followsLatest
        synchronizeRows(from: oldSnapshot, to: state.snapshot)
        if let event = events.first(where: {
            switch $0 {
            case .followLatestRequested, .followLatestChanged,
                 .scrollToEndRequested, .rowRevealRequested:
                return true
            default:
                return false
            }
        }) {
            switch event {
            case let .followLatestRequested(_, animated),
                 let .scrollToEndRequested(_, animated):
                _ = animated // The surface intentionally performs no transcript-wide animation.
                scrollToEnd()
            case let .followLatestChanged(_, enabled, animated):
                _ = animated
                if enabled { scrollToEnd() }
            case let .rowRevealRequested(_, rowID, _):
                reveal(rowID: rowID)
            default:
                break
            }
        } else if followsLatest {
            scrollToEnd()
        } else if let anchor, command.anchorPolicy != .followLatest {
            restore(anchor)
        }
        return events
    }

    @discardableResult
    func perform(_ command: TranscriptSurfaceCommand) -> [TranscriptSurfaceEvent] {
        apply(command)
    }

    /// Viewport operations are kept separate from core snapshot mutations so a
    /// scroll/reveal never consumes a session revision.
    @discardableResult
    func perform(_ operation: AppKitTranscriptSurfaceOperation) -> [TranscriptSurfaceEvent] {
        switch operation {
        case let .scrollToEnd(animated):
            _ = animated // Always immediate: wheel input must not be overwritten.
            scrollToEnd()
            return [.followLatestRequested(session: snapshot.session, animated: false)]
        case let .reveal(rowID, animated):
            _ = animated
            reveal(rowID: rowID)
            return []
        case let .setFollowLatest(enabled):
            userDetachedFromLatest = !enabled
            followsLatest = enabled
            if enabled { scrollToEnd() }
            return enabled
                ? [.followLatestRequested(session: snapshot.session, animated: false)]
                : []
        case let .invalidate(rowIDs):
            invalidate(rowIDs: rowIDs)
            return []
        }
    }

    func scrollToEnd() {
        setContentOffset(y: max(0, heightIndex.totalHeight - scrollView.contentView.bounds.height))
    }

    func reveal(rowID: String) {
        guard let index = snapshot.rows.firstIndex(where: { $0.id == rowID }) else { return }
        let top = heightIndex.offset(of: index)
        let bottom = top + (heightIndex.height(at: index) ?? 0)
        let viewportTop = contentOffsetY
        let viewportBottom = viewportTop + scrollView.contentView.bounds.height
        let next: CGFloat
        if top < viewportTop {
            next = top
        } else if bottom > viewportBottom {
            next = bottom - scrollView.contentView.bounds.height
        } else {
            next = viewportTop
        }
        setContentOffset(y: next)
    }

    func setFollowLatest(_ enabled: Bool) {
        userDetachedFromLatest = !enabled
        followsLatest = enabled
        _ = perform(.setFollowLatest(enabled))
    }

    /// Synchronously called by `AppKitTranscriptScrollView` before AppKit
    /// applies a wheel delta.  This is intentionally not a revisioned surface
    /// command: scrolling is viewport state, and marking the tail detached
    /// must not reject the next producer snapshot.
    func userDidScroll() {
        userDetachedFromLatest = true
        followsLatest = false
        onViewportChanged?(isAtEnd, true)
    }

    func invalidate(rowIDs: [String]) {
        guard !rowIDs.isEmpty else { return }
        let ids = Set(rowIDs)
        measuredHeights = measuredHeights.filter { !ids.contains($0.key) }
        // Local invalidation is deliberately one layout pass.  It never
        // changes the session snapshot or starts a transcript-wide animation.
        relayoutNow()
    }

    func documentDidLayout() {
        guard !layingOut else { return }
        updateMountedFrames()
    }

    private func accepted(_ events: [TranscriptSurfaceEvent]) -> Bool {
        events.contains { event in
            switch event {
            case .snapshotApplied,
                 .rowDisclosureChanged,
                 .followLatestRequested,
                 .followLatestChanged,
                 .scrollToEndRequested,
                 .rowRevealRequested,
                 .rowsInvalidated:
                return true
            default:
                return false
            }
        }
    }

    private func anchorBefore(
        _ policy: TranscriptSurfaceAnchorPolicy,
        oldSnapshot: TranscriptSurfaceSnapshot
    ) -> TranscriptSurfaceAnchor? {
        switch policy {
        case let .preserve(anchor): return anchor
        case .followLatest: return nil
        case .keepViewport: return oldSnapshot.anchor ?? currentVisibleAnchor()
        }
    }

    private func synchronizeRows(
        from oldSnapshot: TranscriptSurfaceSnapshot,
        to newSnapshot: TranscriptSurfaceSnapshot
    ) {
        let oldRows = Dictionary(uniqueKeysWithValues: oldSnapshot.rows.map { ($0.id, $0) })
        let newRows = Dictionary(uniqueKeysWithValues: newSnapshot.rows.map { ($0.id, $0) })
        for id in Array(mounted.keys) {
            guard let cell = mounted[id] else { continue }
            guard let row = newRows[id] else {
                unmount(id: id, cell: cell)
                continue
            }
            let nextKey = AppKitTranscriptRowReuseKey(row: row)
            if cell.key == nextKey,
               oldRows[id]?.contentIdentity == row.contentIdentity {
                // Stable rows are immutable render units.  Keep the host
                // object and its content untouched; only its frame may move
                // after a preceding row's height changes.
            } else {
                unmount(id: id, cell: cell)
            }
        }

        measuredHeights = measuredHeights.filter { id, entry in
            guard let row = newRows[id] else { return false }
            return row.contentIdentity == entry.identity
        }
        let heights = newSnapshot.rows.map { row in
            measuredHeights[row.id].flatMap { $0.identity == row.contentIdentity ? $0.height : nil }
                ?? row.estimatedHeight
        }
        heightIndex.replace(with: heights)
        updateDocumentFrame()
        relayoutNow()
    }

    private func updateDocumentFrame() {
        let width = max(scrollView.contentView.bounds.width, scrollView.bounds.width, 1)
        let height = max(heightIndex.totalHeight, 1)
        document.setFrameSize(NSSize(width: width, height: height))
    }

    private func relayoutNow() {
        guard !layingOut else { return }
        layingOut = true
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            layingOut = false
            let duration = max(0, ProcessInfo.processInfo.systemUptime - started)
            metrics.recordLayout(duration: duration)
        }
        updateDocumentFrame()
        updateMountedFrames()
    }

    private func updateMountedFrames() {
        guard document != nil else { return }
        let viewport = scrollView.contentView.bounds
        let overscanRange = heightIndex.rows(
            intersecting: viewport.minY,
            viewportHeight: viewport.height,
            overscan: overscan
        )
        let visibleRange = heightIndex.rows(
            intersecting: viewport.minY,
            viewportHeight: viewport.height,
            overscan: 0
        )
        var targetIndices = Array(overscanRange)
        if targetIndices.count > maximumMountedRows {
            let visible = Set(visibleRange)
            let center = viewport.midY
            targetIndices = Array(targetIndices.sorted { lhs, rhs in
                let leftDistance = visible.contains(lhs) ? -1 : abs(heightIndex.offset(of: lhs) + (heightIndex.height(at: lhs) ?? 0) / 2 - center)
                let rightDistance = visible.contains(rhs) ? -1 : abs(heightIndex.offset(of: rhs) + (heightIndex.height(at: rhs) ?? 0) / 2 - center)
                return leftDistance < rightDistance
            }.prefix(maximumMountedRows)).sorted()
        }
        let targetIDs = Set(targetIndices.compactMap { index in
            snapshot.rows.indices.contains(index) ? snapshot.rows[index].id : nil
        })

        let staleIDs = mounted.keys.filter { !targetIDs.contains($0) }
        for id in staleIDs {
            if let cell = mounted[id] {
                unmount(id: id, cell: cell)
            }
        }

        for index in targetIndices where snapshot.rows.indices.contains(index) {
            let row = snapshot.rows[index]
            let key = AppKitTranscriptRowReuseKey(row: row)
            if let cell = mounted[row.id] {
                if cell.key != key {
                    unmount(id: row.id, cell: cell)
                } else {
                    position(cell.host, at: index)
                    continue
                }
            }
            let host: AppKitTranscriptRowHost
            let reused: Bool
            if let pooled = reusableHosts.popLast() {
                host = pooled
                host.prepareForReuse()
                host.configure(row: row, key: key)
                reused = true
            } else {
                host = rowFactory(row, key)
                reused = false
            }
            host.frame = NSRect(x: 0, y: heightIndex.offset(of: index), width: document.bounds.width, height: heightIndex.height(at: index) ?? 1)
            document.addSubview(host)
            mounted[row.id] = AppKitTranscriptMountedCell(key: key, host: host)
            metrics.recordMount(count: 1, peak: mounted.count, reused: reused)
        }
        updateMountedFramesWithoutMounting()
    }

    private func updateMountedFramesWithoutMounting() {
        for (id, cell) in mounted {
            guard let index = snapshot.rows.firstIndex(where: { $0.id == id }) else { continue }
            position(cell.host, at: index)
        }
    }

    private func position(_ host: AppKitTranscriptRowHost, at index: Int) {
        host.frame = NSRect(
            x: 0,
            y: heightIndex.offset(of: index),
            width: document.bounds.width,
            height: heightIndex.height(at: index) ?? 1
        )
    }

    private func unmount(id: String, cell: AppKitTranscriptMountedCell) {
        mounted.removeValue(forKey: id)
        cell.host.removeFromSuperview()
        if reusableHosts.count < maximumReusableHosts {
            reusableHosts.append(cell.host)
        }
        metrics.recordUnmount(count: 1)
    }

    private func restore(_ anchor: TranscriptSurfaceAnchor) {
        guard let index = snapshot.rows.firstIndex(where: { $0.id == anchor.rowID }) else { return }
        let next = heightIndex.offset(of: index) - anchor.offset
        setContentOffset(y: next)
    }

    private var isAtEnd: Bool {
        let maxY = max(0, heightIndex.totalHeight - scrollView.contentView.bounds.height)
        return abs(contentOffsetY - maxY) <= 1
    }

    private static func widthBucket(_ width: CGFloat) -> Int {
        Int((max(0, width) * 2).rounded())
    }

    private func requestsFollowLatest(_ kind: TranscriptSurfaceCommand.Kind) -> Bool {
        switch kind {
        case .followLatest, .setFollowLatest(true, _), .scrollToEnd:
            return true
        default:
            return false
        }
    }
}

/// Viewport operations are intentionally not revisioned: they affect only
/// AppKit's clip view and never mutate the Pi session snapshot.
enum AppKitTranscriptSurfaceOperation: Equatable {
    case scrollToEnd(animated: Bool)
    case reveal(rowID: String, animated: Bool)
    case setFollowLatest(Bool)
    case invalidate(rowIDs: [String])
}

typealias TranscriptSurfaceViewportCommand = AppKitTranscriptSurfaceOperation
