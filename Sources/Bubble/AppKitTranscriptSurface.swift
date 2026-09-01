import AppKit
import Darwin
import Foundation

private func transcriptThreadCPUTime() -> TimeInterval {
    var value = timespec()
    guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0 else { return 0 }
    return TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000
}

/// A small, deterministic identity for an AppKit row host.  The content hash
/// is deliberately not part of this key: contentVersion is the producer's
/// explicit invalidation boundary and lets hosts be reused without comparing
/// large message bodies on every layout pass.
struct AppKitTranscriptRowReuseKey: Equatable, Hashable {
    let kind: TranscriptRowKind
    let id: String
    let contentVersion: UInt64
    let isCompleted: Bool
    /// Anchor ownership is part of the mounted row's semantic output. A
    /// branch/replay may keep prose content stable while moving a continuation
    /// under a different user turn; reusing that host would leave a stale
    /// history marker in the mounted tree.
    let historyTickID: String?
    let layoutIdentity: TranscriptRowLayoutIdentity

    init(
        kind: TranscriptRowKind,
        id: String,
        contentVersion: UInt64,
        isCompleted: Bool = true,
        historyTickID: String? = nil,
        layoutIdentity: TranscriptRowLayoutIdentity = .default
    ) {
        self.kind = kind
        self.id = id
        self.contentVersion = contentVersion
        self.isCompleted = isCompleted
        self.historyTickID = historyTickID
        self.layoutIdentity = layoutIdentity
    }

    init(row: TranscriptRowSnapshot) {
        self.init(
            kind: row.kind,
            id: row.id,
            contentVersion: row.contentVersion,
            isCompleted: row.isCompleted,
            historyTickID: row.historyTickID,
            layoutIdentity: row.layoutIdentity
        )
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
        layer?.masksToBounds = true
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

    /// The content's preferred height at the host's current width. Rich hosts
    /// override this with their renderer-backed fitting measurement.
    var preferredContentHeight: CGFloat { intrinsicContentSize.height }

    /// True when a visible host must reconcile its frame before painting.
    /// Newly mounted hosts are measured regardless; this hook also covers an
    /// overscan host that became dirty before it entered the viewport.
    var needsImmediateContentMeasurement: Bool { false }

    /// Marks renderer-owned intrinsic content dirty before a deferred
    /// reconciliation pass. Plain AppKit fallback rows have no delayed
    /// renderer transaction, so their default implementation is a no-op.
    func invalidateContentMeasurement() {}
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
    private(set) var heightIndexRebuilds = 0
    private(set) var heightIndexPointUpdates = 0
    /// Work performed synchronously in response to a clip-origin change.
    /// This is the input-to-visible path and must stay bounded independently
    /// of the deferred overscan refill cadence.
    private(set) var synchronousViewportLayoutCount = 0
    private(set) var lastSynchronousViewportDuration: TimeInterval = 0
    private(set) var maximumSynchronousViewportDuration: TimeInterval = 0
    /// Deferred work is intentionally time-sliced so a large rich-row cache
    /// can never consume two display frames in one callback.
    private(set) var deferredOverscanRefillCount = 0
    private(set) var lastDeferredOverscanRefillDuration: TimeInterval = 0
    private(set) var maximumDeferredOverscanRefillDuration: TimeInterval = 0
    private(set) var deferredOverscanRefillMounts = 0
    private(set) var maximumDeferredOverscanRefillMounts = 0
    /// Index-addressed streaming updates must inspect one producer row and
    /// never walk the immutable transcript prefix. These counters make that
    /// contract observable in focused checks and debug telemetry.
    private(set) var rowUpdateCount = 0
    private(set) var rowUpdateInspectedRows = 0
    private(set) var rowUpdateMountedHosts = 0

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

    mutating func recordHeightIndexRebuild() {
        heightIndexRebuilds += 1
    }

    mutating func recordHeightIndexPointUpdate() {
        heightIndexPointUpdates += 1
    }

    mutating func recordSynchronousViewportWork(duration: TimeInterval) {
        synchronousViewportLayoutCount += 1
        lastSynchronousViewportDuration = duration
        maximumSynchronousViewportDuration = max(maximumSynchronousViewportDuration, duration)
    }

    mutating func recordDeferredOverscanRefill(duration: TimeInterval, mountedRows: Int) {
        deferredOverscanRefillCount += 1
        lastDeferredOverscanRefillDuration = duration
        maximumDeferredOverscanRefillDuration = max(maximumDeferredOverscanRefillDuration, duration)
        let boundedRows = max(0, mountedRows)
        deferredOverscanRefillMounts += boundedRows
        maximumDeferredOverscanRefillMounts = max(maximumDeferredOverscanRefillMounts, boundedRows)
    }

    mutating func recordRowUpdate(inspectedRows: Int, mountedHosts: Int) {
        rowUpdateCount += 1
        rowUpdateInspectedRows += max(0, inspectedRows)
        rowUpdateMountedHosts += max(0, mountedHosts)
    }
}

/// The clip view used by the production surface.  AppKit's bounds-change
/// notification is delivered after the scroll wheel has already been
/// interpreted, which is too late for the composer/follow policy: a new wheel
/// event must detach from the tail before the next streamed token arrives.
/// Keep this hook at the physical input boundary and let the adapter decide
/// whether the event is user-driven or programmatic.
enum TranscriptChromeHitTestPolicy {
    private static let buttonSize: CGFloat = 28
    private static let buttonSpacing: CGFloat = 2
    private static let edgePadding: CGFloat = 6

    static func containsLoopButton(
        _ point: NSPoint,
        in bounds: NSRect,
        flipped: Bool
    ) -> Bool {
        guard bounds.contains(point) else { return false }
        let distanceFromRight = bounds.maxX - point.x
        let distanceFromTop = flipped
            ? point.y - bounds.minY
            : bounds.maxY - point.y
        let loopMinimumX = edgePadding + 2 * (buttonSize + buttonSpacing)
        return distanceFromRight >= loopMinimumX
            && distanceFromRight <= loopMinimumX + buttonSize
            && distanceFromTop >= edgePadding
            && distanceFromTop <= edgePadding + buttonSize
    }
}

final class AppKitTranscriptScrollView: NSScrollView {
    var onUserScroll: ((NSEvent) -> Void)?
    var onUserScrollDidApply: (() -> Void)?
    var onDiscreteWheel: ((NSEvent) -> Bool)?
    var onPreciseWheelBegan: ((NSEvent) -> Bool)?
    var onLoopButtonClick: (() -> Void)?
    var isDiagnosticOverscanReady: (() -> Bool)?
    private var localWheelMonitor: Any?
    private var localMouseMonitor: Any?
    private(set) var localWheelHandlerGeneration: UInt64 = 0
    private(set) var lastLocalWheelHandlerDuration: TimeInterval = 0

    deinit {
        removeLocalWheelMonitor()
        removeLocalMouseMonitor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeLocalWheelMonitor()
        removeLocalMouseMonitor()
        guard window != nil else { return }
        localWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleLocalWheelEvent(event) ?? event
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleLocalMouseDown(event) ?? event
        }
    }

    private func handleLocalMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let window,
              window.isVisible,
              event.windowNumber == window.windowNumber,
              let onLoopButtonClick else { return event }
        let point = convert(event.locationInWindow, from: nil)
        guard TranscriptChromeHitTestPolicy.containsLoopButton(
            point,
            in: bounds,
            flipped: isFlipped
        ) else { return event }
        onLoopButtonClick()
        return nil
    }

    private func handleLocalWheelEvent(_ event: NSEvent) -> NSEvent? {
        guard let window,
              window.isVisible,
              !isHiddenOrHasHiddenAncestor,
              TranscriptWheelCapturePolicy.shouldCapture(
                  deltaX: event.scrollingDeltaX,
                  deltaY: event.scrollingDeltaY
              ) else { return event }
        let location: NSPoint
        if event.windowNumber == window.windowNumber {
            location = convert(event.locationInWindow, from: nil)
        } else if event.windowNumber == 0 {
            location = convert(
                window.convertPoint(fromScreen: event.locationInWindow),
                from: nil
            )
        } else {
            return event
        }
        guard bounds.contains(location) else { return event }

        // Capture before hit testing reaches an embedded SwiftUI table,
        // code scroller, or web view. Returning nil prevents the same
        // physical packet from being dispatched a second time.
        let started = transcriptThreadCPUTime()
        scrollWheel(with: event)
        lastLocalWheelHandlerDuration = max(
            0,
            transcriptThreadCPUTime() - started
        )
        localWheelHandlerGeneration &+= 1
        return nil
    }

    private func removeLocalWheelMonitor() {
        guard let localWheelMonitor else { return }
        NSEvent.removeMonitor(localWheelMonitor)
        self.localWheelMonitor = nil
    }

    private func removeLocalMouseMonitor() {
        guard let localMouseMonitor else { return }
        NSEvent.removeMonitor(localMouseMonitor)
        self.localMouseMonitor = nil
    }

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?(event)
        let handledPreciseBegin = event.hasPreciseScrollingDeltas
            && event.phase == .began
            && onPreciseWheelBegan?(event) == true
        if !handledPreciseBegin,
           event.hasPreciseScrollingDeltas || onDiscreteWheel?(event) != true {
            super.scrollWheel(with: event)
        }
        onUserScrollDidApply?()
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
    /// Production rendering uses the non-recording reducer.  The recording
    /// wrapper is intentionally confined to Foundation focused checks so a
    /// streamed session cannot retain one command/event array per revision.
    private let state: TranscriptSurfaceState
    private let rowFactory: AppKitTranscriptRowHostFactory
    private let overscan: CGFloat
    private let maximumMountedRows: Int
    private let maximumReusableHosts: Int
    /// Overscan is a warm cache, not part of the input-to-visible path. Keep
    /// its refill bounded both by rows and wall time so a first traversal of
    /// a rich transcript cannot monopolize two display frames.
    private let maximumDeferredOverscanMountsPerPass: Int
    private let maximumDeferredOverscanDuration: TimeInterval
    private var document: AppKitTranscriptDocumentView!
    private var clipBoundsObserver: NSObjectProtocol?
    private var mounted: [String: AppKitTranscriptMountedCell] = [:]
    /// Detached cells remain keyed by their immutable row identity. Returning
    /// to a row therefore reattaches the existing rich tree without another
    /// root transaction; a bounded LRU fallback still permits reuse when the
    /// row identity has changed.
    private var reusableHostsByKey: [AppKitTranscriptRowReuseKey: AppKitTranscriptRowHost] = [:]
    private var reusableHostLRU: [AppKitTranscriptRowReuseKey] = []
    private var rowIndexByID: [String: Int] = [:]
    private var heightIndex: TranscriptHeightIndex
    private var layingOut = false
    private var followsLatest = false
    private var userDetachedFromLatest = false
    private var widthBucket: Int = 0
    private var lastVisibleRowIDs: Set<String> = []
    /// Tracks the previous viewport's semantic rows so an already-mounted
    /// overscan host is measured on the exact pass where it becomes visible.
    private var immediatelyMeasuredVisibleRowIDs: Set<String> = []
    private var lastNeutralAtEnd: Bool?
    private var viewportReportQueued = false
    private var lastViewportReportUptime: TimeInterval = -.greatestFiniteMagnitude
    private var lastUserScrollUptime: TimeInterval = -.greatestFiniteMagnitude
    private var awaitsPhaseLessWheelBounds = false
    private var phaseLessWheelGeneration: UInt64 = 0
    private var phaseLessWheelFallbackWorkItem: DispatchWorkItem?
    private var settledMeasurementWorkItem: DispatchWorkItem?
    private var settledMeasurementGeneration: UInt64 = 0
    private var overscanRefillQueued = false
    /// A visible row must not paint with its producer estimate while its rich
    /// host is waiting for AppKit's next layout pass. Measurements discovered
    /// while synchronously laying out a mount are collected here and committed
    /// as one height-index batch, keeping the input-to-visible path bounded.
    private var synchronousVisibleMeasurementDepth = 0
    private var pendingVisibleMeasurements: [String: CGFloat] = [:]
    private(set) var metrics = AppKitTranscriptSurfaceMetrics()

    let scrollView: AppKitTranscriptScrollView
    /// Called after a viewport change.  The boolean identifies a physical
    /// user wheel event; programmatic reveal/follow operations report false.
    var onViewportChanged: ((_ atEnd: Bool, _ userDriven: Bool) -> Void)?
    /// Fires once at the start of a physical wheel sequence.  The viewport
    /// callback still reports every pre/post packet, but selection/hover
    /// teardown must not mutate every mounted row on every packet.
    var onUserScrollSequenceStarted: (() -> Void)?

    init(
        snapshot: TranscriptSurfaceSnapshot? = nil,
        overscan: CGFloat = 560,
        maximumMountedRows: Int = 96,
        maximumReusableHosts: Int = 160,
        maximumDeferredOverscanMountsPerPass: Int = 4,
        maximumDeferredOverscanDuration: TimeInterval = 0.004,
        renderer: @escaping AppKitTranscriptRowHostFactory = { row, key in
            AppKitTranscriptRowHost(row: row, key: key)
        }
    ) {
        self.state = TranscriptSurfaceState(snapshot: snapshot)
        self.rowFactory = renderer
        self.overscan = max(0, overscan)
        self.maximumMountedRows = max(1, maximumMountedRows)
        self.maximumReusableHosts = max(0, maximumReusableHosts)
        self.maximumDeferredOverscanMountsPerPass = max(1, maximumDeferredOverscanMountsPerPass)
        self.maximumDeferredOverscanDuration = max(0.0005, maximumDeferredOverscanDuration)
        self.heightIndex = TranscriptHeightIndex(
            heights: (snapshot?.rows ?? []).map(\.estimatedHeight)
        )
        self.rowIndexByID = Dictionary(
            uniqueKeysWithValues: (snapshot?.rows ?? []).enumerated().map { ($0.element.id, $0.offset) }
        )
        self.followsLatest = snapshot?.followsLatest ?? false
        self.scrollView = AppKitTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        super.init()

        scrollView.isDiagnosticOverscanReady = { [weak self] in
            guard let self else { return false }
            return !self.hasMissingOverscanRows
        }

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // The transcript historically hid its SwiftUI scroll indicators.
        // Keep the AppKit surface visually quiet as well; wheel, trackpad,
        // keyboard, and programmatic scrolling do not require a scroller.
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.onUserScroll = { [weak self] event in
            self?.userDidScroll(event: event)
        }
        scrollView.onUserScrollDidApply = { [weak self] in
            self?.userScrollDidApply()
        }
        scrollView.onDiscreteWheel = { [weak self] event in
            self?.applyDiscreteWheel(event) ?? false
        }
        scrollView.onPreciseWheelBegan = { [weak self] event in
            self?.applyPreciseWheelBegin(event) ?? false
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
            let userDrivenPhaseLessWheel = self.awaitsPhaseLessWheelBounds
            if userDrivenPhaseLessWheel {
                self.awaitsPhaseLessWheelBounds = false
                self.phaseLessWheelGeneration &+= 1
                self.phaseLessWheelFallbackWorkItem?.cancel()
                self.phaseLessWheelFallbackWorkItem = nil
            }
            self.layoutViewportNow()
            // Bounds changes are deliberately neutral.  Window resizing,
            // elastic settling, and measurement clamps all arrive through
            // this path too; only `scrollWheel(with:)` calls userDidScroll()
            // and reports userDriven=true.
            let atEnd = self.isAtEnd
            if userDrivenPhaseLessWheel {
                self.onViewportChanged?(atEnd, true)
            } else if self.lastNeutralAtEnd != atEnd {
                self.lastNeutralAtEnd = atEnd
                self.onViewportChanged?(atEnd, false)
            }
        }
        relayoutNow()
    }

    deinit {
        settledMeasurementWorkItem?.cancel()
        phaseLessWheelFallbackWorkItem?.cancel()
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
    var reusableHostCount: Int { reusableHostsByKey.count }
    var contentOverflowDiagnostics: (count: Int, maximum: CGFloat) {
        // Masked row hosts cannot paint into adjacent rows. Keep this metric
        // about actual visual overlap; the separate mismatch metric below
        // verifies that clipping is only a transient safety boundary.
        contentHeightDiagnostics(includeMaskedHosts: false)
    }
    var contentHeightMismatchDiagnostics: (count: Int, maximum: CGFloat) {
        contentHeightDiagnostics(includeMaskedHosts: true)
    }

    private func contentHeightDiagnostics(
        includeMaskedHosts: Bool
    ) -> (count: Int, maximum: CGFloat) {
        var count = 0
        var maximum: CGFloat = 0
        let viewport = scrollView.contentView.bounds
        for cell in mounted.values
        where !cell.host.isHidden && cell.host.frame.intersects(viewport) {
            if !includeMaskedHosts, cell.host.layer?.masksToBounds == true {
                continue
            }
            let contentHeight = cell.host.preferredContentHeight
            guard contentHeight.isFinite, contentHeight > cell.host.bounds.height + 1 else { continue }
            count += 1
            maximum = max(maximum, contentHeight - cell.host.bounds.height)
        }
        return (count, maximum)
    }
    var currentHeightIndex: TranscriptHeightIndex { heightIndex }
    var visibleMountedRowIDs: [String] {
        let viewport = scrollView.contentView.bounds
        return mounted.compactMap { rowID, cell in
            !cell.host.isHidden && cell.host.frame.intersects(viewport) ? rowID : nil
        }
    }
    var visibleCoverageGap: CGFloat {
        let viewport = scrollView.contentView.bounds
        guard viewport.height > 0 else { return 0 }
        let intervals = mounted.values.compactMap { cell -> ClosedRange<CGFloat>? in
            guard !cell.host.isHidden, cell.host.frame.intersects(viewport) else { return nil }
            return max(viewport.minY, cell.host.frame.minY)...min(viewport.maxY, cell.host.frame.maxY)
        }.sorted { $0.lowerBound < $1.lowerBound }
        var cursor = viewport.minY
        var gap: CGFloat = 0
        for interval in intervals {
            if interval.lowerBound > cursor {
                gap += interval.lowerBound - cursor
            }
            cursor = max(cursor, interval.upperBound)
        }
        if cursor < viewport.maxY {
            gap += viewport.maxY - cursor
        }
        return gap
    }
    var isUserScrollActive: Bool {
        ProcessInfo.processInfo.systemUptime - lastUserScrollUptime <= 0.35
    }
    var visibleRowIDs: [String] {
        let viewport = scrollView.contentView.bounds
        let range = heightIndex.rows(
            intersecting: viewport.minY,
            viewportHeight: viewport.height,
            overscan: 0
        )
        return range.compactMap { index in
            snapshot.rows.indices.contains(index) ? snapshot.rows[index].id : nil
        }
    }

    var visibleHistoryTickIDs: [String] {
        let viewport = scrollView.contentView.bounds
        let range = heightIndex.rows(
            intersecting: viewport.minY,
            viewportHeight: viewport.height,
            overscan: 0
        )
        return range.compactMap { index in
            guard snapshot.rows.indices.contains(index) else { return nil }
            let row = snapshot.rows[index]
            return row.historyTickID ?? row.id
        }
    }

    /// A cheap viewport helper used by deterministic checks and by the future
    /// NSViewRepresentable bridge.  It never waits for row measurement.
    func setViewportSize(_ size: NSSize) {
        let nextBucket = Self.widthBucket(size.width)
        let currentSize = scrollView.frame.size
        let sizeChanged = abs(currentSize.width - size.width) > 0.5
            || abs(currentSize.height - size.height) > 0.5
        guard sizeChanged || nextBucket != widthBucket else { return }
        let anchor = nextBucket != widthBucket ? currentVisibleAnchor() : nil
        if sizeChanged {
            scrollView.setFrameSize(size)
        }
        if nextBucket != widthBucket {
            widthBucket = nextBucket
            // Width is part of text layout identity.  Keep prior buckets in
            // the shared cache and restore whichever measurements exist for
            // this bucket instead of throwing away all completed-row layout.
            heightIndex.replace(with: snapshot.rows.map(cachedHeightOrEstimate))
            metrics.recordHeightIndexRebuild()
            updateDocumentFrame()
            if followsLatest {
                scrollToEnd()
            } else if let anchor {
                restore(anchor)
            }
        }
        relayoutNow()
    }

    func setContentOffset(y: CGFloat) {
        let maxY = max(0, heightIndex.totalHeight - scrollView.contentView.bounds.height)
        let clamped = min(max(0, y), maxY)
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: clamped))
    }

    /// AppKit deliberately smooths line-based mouse-wheel events, which can
    /// defer the first visible movement by several packets.  Apply one
    /// bounded line step synchronously; precise trackpad deltas retain native
    /// AppKit momentum through `super.scrollWheel`.
    private func applyDiscreteWheel(_ event: NSEvent) -> Bool {
        guard !event.hasPreciseScrollingDeltas else { return false }
        let resolved = TranscriptWheelScrollPolicy.resolvedDelta(
            scrollingDeltaY: event.scrollingDeltaY,
            hasPreciseDeltas: false
        )
        // Keep one accelerated mouse packet within one layout step. A larger
        // cap feels faster in empty views but can cross a rich-row boundary
        // and create multiple SwiftUI hosts in the same display frame.
        let cap = TranscriptWheelFramePolicy.maximumStep(hasPreciseDeltas: false)
        let bounded = min(cap, max(-cap, resolved))
        guard abs(bounded) > 0.01 else { return true }
        setContentOffset(y: contentOffsetY - bounded)
        return true
    }

    /// Native AppKit momentum owns the rest of a trackpad gesture, but its
    /// first packet can wait for the scroll-physics transaction. Commit one
    /// bounded `.began` delta immediately so the user's reversal is visible
    /// in the same frame, then hand subsequent packets back to AppKit.
    private func applyPreciseWheelBegin(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas, event.phase == .began else { return false }
        let delta = TranscriptWheelScrollPolicy.resolvedDelta(
            scrollingDeltaY: event.scrollingDeltaY,
            hasPreciseDeltas: true
        )
        let cap = TranscriptWheelFramePolicy.maximumStep(hasPreciseDeltas: true)
        let bounded = min(cap, max(-cap, delta))
        guard abs(bounded) > 0.01 else { return false }
        setContentOffset(y: contentOffsetY - bounded)
        return true
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
        guard let index = rowIndexByID[rowID], snapshot.rows.indices.contains(index) else { return false }
        if synchronousVisibleMeasurementDepth > 0 {
            let current = heightIndex.height(at: index) ?? 1
            pendingVisibleMeasurements[rowID] = height
            return abs(current - height) > 0.5
        }
        return commitMeasuredHeight(rowID: rowID, height: height)
    }

    /// Commits one measured row outside the synchronous first-mount batch.
    /// Keeping the existing anchor/follow behavior here preserves the normal
    /// asynchronous intrinsic-size callback semantics.
    @discardableResult
    private func commitMeasuredHeight(rowID: String, height: CGFloat) -> Bool {
        guard let index = rowIndexByID[rowID], snapshot.rows.indices.contains(index) else { return false }
        let anchor = currentVisibleAnchor()
        let row = snapshot.rows[index]
        heightCache.insert(height, for: layoutCacheKey(for: row))
        let changed = heightIndex.update(index: index, height: height) != 0
        if changed {
            metrics.recordHeightIndexPointUpdate()
        }
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

    /// Flushes intrinsic heights collected while newly mounted visible hosts
    /// were laid out. The update is intentionally one Fenwick batch followed
    /// by one document/frame reposition, rather than recursively re-entering
    /// `relayoutNow()` once per host callback.
    private func commitPendingVisibleMeasurements() -> Bool {
        guard !pendingVisibleMeasurements.isEmpty else { return false }
        let pending = pendingVisibleMeasurements
        pendingVisibleMeasurements.removeAll(keepingCapacity: true)
        var heightChanged = false
        for (rowID, height) in pending {
            guard let index = rowIndexByID[rowID], snapshot.rows.indices.contains(index) else { continue }
            let row = snapshot.rows[index]
            heightCache.insert(height, for: layoutCacheKey(for: row))
            if heightIndex.update(index: index, height: height) != 0 {
                metrics.recordHeightIndexPointUpdate()
                heightChanged = true
            }
        }
        guard heightChanged else { return false }
        updateDocumentFrame()
        // The caller is already in a bounded mount/layout pass. Reposition the
        // mounted window directly instead of recursively entering relayoutNow.
        updateMountedFramesWithoutMounting()
        if followsLatest {
            scrollToEnd()
        }
        return true
    }

    /// Forces AppKit to lay out each newly mounted visible host and samples its
    /// intrinsic content height before the frame is exposed to the user. Rich
    /// Overlay hosts may also invoke `updateMeasuredHeight` from their layout;
    /// the depth guard above coalesces those callbacks into the same batch.
    private func synchronouslyMeasureVisibleMounts(
        _ mounts: [(rowID: String, host: AppKitTranscriptRowHost)]
    ) -> Bool {
        guard !mounts.isEmpty else { return false }
        synchronousVisibleMeasurementDepth += 1
        for mount in mounts {
            guard mounted[mount.rowID]?.host === mount.host else { continue }
            mount.host.layoutSubtreeIfNeeded()
            let measured = mount.host.preferredContentHeight
            guard measured.isFinite, measured > 0 else { continue }
            pendingVisibleMeasurements[mount.rowID] = measured
        }
        synchronousVisibleMeasurementDepth -= 1
        // These measurements belong only to rows intersecting the current
        // viewport. Changing their heights cannot move their top offsets, so
        // preserving the clip origin is the stable anchor. Calling restore()
        // here would mutate bounds while layoutViewportNow() is guarded by
        // `layingOut`, dropping the resulting remount pass and exposing a
        // blank viewport for one frame.
        return commitPendingVisibleMeasurements()
    }

    @discardableResult
    func apply(_ command: TranscriptSurfaceCommand) -> [TranscriptSurfaceEvent] {
        // Streaming token updates carry the affected row identity. Handle
        // those through the index-addressed path before taking a snapshot;
        // retaining `state.snapshot` here would alias the full rows Array and
        // force a copy-on-write allocation when the reducer mutates one item.
        if case let .update(row) = command.kind {
            return applyStreamingRowUpdate(row: row, command: command)
        }
        let oldSnapshot = state.snapshot
        let anchor = anchorBefore(command.anchorPolicy, oldSnapshot: oldSnapshot)
        let events = state.apply(command)
        guard accepted(events) else { return events }

        if case .replace = command.kind,
           (oldSnapshot.session.sessionID != state.snapshot.session.sessionID
                || oldSnapshot.session.generation != state.snapshot.session.generation) {
            immediatelyMeasuredVisibleRowIDs.removeAll(keepingCapacity: true)
            for (id, cell) in Array(mounted) {
                unmount(id: id, cell: cell)
            }
            for host in reusableHostsByKey.values {
                host.removeFromSuperview()
                host.prepareForReuse()
            }
            reusableHostsByKey.removeAll(keepingCapacity: true)
            reusableHostLRU.removeAll(keepingCapacity: true)
        }

        if requestsFollowLatest(command.kind) {
            userDetachedFromLatest = false
        }
        followsLatest = userDetachedFromLatest ? false : state.snapshot.followsLatest
        synchronizeRows(from: oldSnapshot, to: state.snapshot)
        for event in events {
            if case let .rowDisclosureChanged(_, _, _, invalidatedRowIDs, _) = event,
               !invalidatedRowIDs.isEmpty {
                invalidate(rowIDs: invalidatedRowIDs)
            }
        }
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
        if case .replace = command.kind {
            // Restored NSHostingViews can return the previous/empty fitting
            // height during their first synchronous SwiftUI transaction.
            // Confirm visible rows on the next run-loop turn so historical
            // sessions cannot retain that stale height indefinitely.
            scheduleSettledMeasurements(after: 0)
        }
        return events
    }

    /// Applies one known streaming row without rebuilding the transcript
    /// snapshot, row-index map, or mounted-cell set.  Structural commands keep
    /// using `synchronizeRows` below, while the normal token path performs one
    /// Fenwick point update and one optional host configure.
    private func applyStreamingRowUpdate(
        row: TranscriptRowSnapshot,
        command: TranscriptSurfaceCommand
    ) -> [TranscriptSurfaceEvent] {
        let index = rowIndexByID[row.id]
        let oldRow = index.flatMap { state.row(at: $0) }
        let anchor = anchorBefore(command.anchorPolicy)
        let events = state.apply(command)
        guard accepted(events), let index, let oldRow else { return events }

        if requestsFollowLatest(command.kind) {
            userDetachedFromLatest = false
        }
        followsLatest = userDetachedFromLatest ? false : state.snapshot.followsLatest

        let contentChanged = oldRow.contentIdentity != row.contentIdentity
        let layoutChanged = oldRow.layoutIdentity != row.layoutIdentity
            || oldRow.historyTickID != row.historyTickID
            || oldRow.estimatedHeight != row.estimatedHeight
        let nextKey = AppKitTranscriptRowReuseKey(row: row)
        var mountedHostCount = 0
        if let cell = mounted[row.id] {
            // A live streamed row is safe to reconfigure in place. This keeps
            // its AppKit/SwiftUI host identity stable even as contentVersion
            // advances for every token; completed rows still use the cold
            // structural path and immutable reuse keys.
            if cell.key != nextKey || contentChanged || layoutChanged {
                cell.host.configure(row: row, key: nextKey)
                cell.key = nextKey
            }
            mountedHostCount = 1
        }

        var heightChanged = false
        if contentChanged || layoutChanged {
            let height = cachedHeightOrEstimate(row)
            heightChanged = heightIndex.update(index: index, height: height) != 0
            if heightChanged {
                metrics.recordHeightIndexPointUpdate()
            }
        }
        metrics.recordRowUpdate(inspectedRows: 1, mountedHosts: mountedHostCount)

        if heightChanged {
            updateDocumentFrame()
        }
        if heightChanged || mountedHostCount > 0 {
            // Repositioning is bounded by the mounted viewport window. The
            // immutable offscreen prefix is never traversed here.
            relayoutNow()
        }

        if followsLatest {
            scrollToEnd()
        } else if let anchor, command.anchorPolicy != .followLatest {
            restore(anchor)
        }
        return events
    }

    /// Coalesces the normal same-frame thought + answer mutation into one
    /// AppKit layout/follow pass. State revisions still advance in order, but
    /// the mounted viewport is reflowed only after all point updates land.
    @discardableResult
    func applyStreamingRowUpdates(
        _ updates: [(row: TranscriptRowSnapshot, session: TranscriptSessionHandle)]
    ) -> [[TranscriptSurfaceEvent]] {
        guard updates.count > 1 else {
            return updates.map {
                apply(.update(row: $0.row, session: $0.session, preserving: currentVisibleAnchor()))
            }
        }
        let anchor = currentVisibleAnchor()
        var allEvents: [[TranscriptSurfaceEvent]] = []
        var needsDocumentFrame = false
        var needsRelayout = false
        for update in updates {
            guard let index = rowIndexByID[update.row.id],
                  let oldRow = state.row(at: index) else {
                allEvents.append([])
                continue
            }
            let command = TranscriptSurfaceCommand.update(
                row: update.row,
                session: update.session,
                preserving: anchor
            )
            let events = state.apply(command)
            allEvents.append(events)
            guard accepted(events) else { continue }

            followsLatest = userDetachedFromLatest ? false : state.snapshot.followsLatest
            let contentChanged = oldRow.contentIdentity != update.row.contentIdentity
            let layoutChanged = oldRow.layoutIdentity != update.row.layoutIdentity
                || oldRow.historyTickID != update.row.historyTickID
                || oldRow.estimatedHeight != update.row.estimatedHeight
            let nextKey = AppKitTranscriptRowReuseKey(row: update.row)
            var mountedHostCount = 0
            if let cell = mounted[update.row.id],
               cell.key != nextKey || contentChanged || layoutChanged {
                cell.host.configure(row: update.row, key: nextKey)
                cell.key = nextKey
                mountedHostCount = 1
            }
            if contentChanged || layoutChanged {
                let height = cachedHeightOrEstimate(update.row)
                if heightIndex.update(index: index, height: height) != 0 {
                    metrics.recordHeightIndexPointUpdate()
                    needsDocumentFrame = true
                }
            }
            metrics.recordRowUpdate(inspectedRows: 1, mountedHosts: mountedHostCount)
            needsRelayout = needsRelayout || mountedHostCount > 0 || needsDocumentFrame
        }
        if needsDocumentFrame { updateDocumentFrame() }
        if needsRelayout { relayoutNow() }
        if followsLatest {
            scrollToEnd()
        } else if let anchor {
            restore(anchor)
        }
        return allEvents
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
            userDetachedFromLatest = false
            followsLatest = true
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
        guard let index = rowIndexByID[rowID], snapshot.rows.indices.contains(index) else { return }
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
        userDidScroll(event: nil)
    }

    func userDidScroll(event: NSEvent?) {
        let now = ProcessInfo.processInfo.systemUptime
        if let event,
           event.hasPreciseScrollingDeltas,
           event.phase.isEmpty,
           event.momentumPhase.isEmpty,
           abs(event.scrollingDeltaY) > 0.01 {
            awaitsPhaseLessWheelBounds = true
            phaseLessWheelGeneration &+= 1
            let generation = phaseLessWheelGeneration
            phaseLessWheelFallbackWorkItem?.cancel()
            let fallback = DispatchWorkItem { [weak self] in
                guard let self,
                      self.awaitsPhaseLessWheelBounds,
                      self.phaseLessWheelGeneration == generation else { return }
                self.awaitsPhaseLessWheelBounds = false
                self.phaseLessWheelFallbackWorkItem = nil
                self.onViewportChanged?(self.isAtEnd, true)
            }
            phaseLessWheelFallbackWorkItem = fallback
            // Physical evidence on the affected mouse showed the first native
            // bounds commit arriving about 67 ms after the packet. A boundary
            // event may never move bounds, so settle its end state explicitly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: fallback)
        }
        let phaseBegan = event?.phase == .began || event?.momentumPhase == .began
        if phaseBegan || now - lastUserScrollUptime > 0.35 {
            onUserScrollSequenceStarted?()
        }
        lastUserScrollUptime = now
        settledMeasurementWorkItem?.cancel()
        settledMeasurementWorkItem = nil
        userDetachedFromLatest = true
        followsLatest = false
        // The callback is intentionally sent before `super.scrollWheel` so
        // SwiftUI can detach immediately.  The post-super callback below
        // reports the actual end state after AppKit applies the delta.
        onViewportChanged?(false, true)
    }

    func userScrollDidApply() {
        // The pre-wheel callback already reported the detached state. Only
        // publish a second user-driven transition when the applied delta
        // actually reaches the tail and following must resume.
        if !awaitsPhaseLessWheelBounds, isAtEnd {
            onViewportChanged?(true, true)
        }
        scheduleSettledMeasurements()
    }

    private func scheduleSettledMeasurements(after delay: TimeInterval = 0.36) {
        settledMeasurementWorkItem?.cancel()
        settledMeasurementGeneration &+= 1
        let generation = settledMeasurementGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settledMeasurementWorkItem = nil
            guard !self.isUserScrollActive else {
                self.scheduleSettledMeasurements()
                return
            }
            self.measureSettledRows(
                self.visibleMountedRowIDs,
                generation: generation
            )
        }
        settledMeasurementWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    private func measureSettledRows(_ rowIDs: [String], generation: UInt64) {
        guard generation == settledMeasurementGeneration,
              !isUserScrollActive,
              !rowIDs.isEmpty else { return }
        let batch = rowIDs.prefix(4)
        let hosts = batch.compactMap { rowID -> (rowID: String, host: AppKitTranscriptRowHost)? in
            guard let host = mounted[rowID]?.host else { return nil }
            host.invalidateContentMeasurement()
            return (rowID: rowID, host: host)
        }
        _ = synchronouslyMeasureVisibleMounts(hosts)
        let remaining = Array(rowIDs.dropFirst(batch.count))
        guard !remaining.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.measureSettledRows(remaining, generation: generation)
        }
    }

    func invalidate(rowIDs: [String]) {
        guard !rowIDs.isEmpty else { return }
        for rowID in Set(rowIDs) {
            guard let index = rowIndexByID[rowID], snapshot.rows.indices.contains(index) else { continue }
            heightCache.removeValue(for: layoutCacheKey(for: snapshot.rows[index]))
            // Disclosure and other row-local geometry changes keep the same
            // immutable content identity.  Reconfigure only the mounted row
            // so its SwiftUI tree observes the new local state and can report
            // one fresh measurement; unrelated hosts remain untouched.
            if let cell = mounted[rowID] {
                cell.host.configure(row: snapshot.rows[index], key: cell.key)
            }
        }
        // Local invalidation is deliberately one layout pass.  It never
        // changes the session snapshot or starts a transcript-wide animation.
        relayoutNow()
    }

    func invalidateMountedRowsForLayoutChange() {
        guard !mounted.isEmpty else { return }
        for (rowID, cell) in mounted {
            guard let index = rowIndexByID[rowID], snapshot.rows.indices.contains(index) else { continue }
            let row = snapshot.rows[index]
            heightCache.removeValue(for: layoutCacheKey(for: row))
            cell.host.configure(row: row, key: cell.key)
        }
        relayoutNow()
    }

    func documentDidLayout() {
        guard !layingOut else { return }
        // Document geometry changes are on the visible-correctness path. The
        // warm overscan window is refilled by its bounded deferred scheduler,
        // never while AppKit is already inside a document layout callback.
        updateMountedFrames(repositionExisting: true, mountNewOverscanRows: false)
        scheduleOverscanRefill()
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

    private func anchorBefore(_ policy: TranscriptSurfaceAnchorPolicy) -> TranscriptSurfaceAnchor? {
        switch policy {
        case let .preserve(anchor): return anchor
        case .followLatest: return nil
        case .keepViewport: return state.snapshot.anchor ?? currentVisibleAnchor()
        }
    }

    private func synchronizeRows(
        from oldSnapshot: TranscriptSurfaceSnapshot,
        to newSnapshot: TranscriptSurfaceSnapshot
    ) {
        let sameRowSequence = oldSnapshot.rows.count == newSnapshot.rows.count
            && oldSnapshot.rows.indices.allSatisfy { index in
                oldSnapshot.rows[index].id == newSnapshot.rows[index].id
            }
        if sameRowSequence {
            // A streamed revision normally changes only the live tail. Avoid
            // allocating two O(N) ID dictionaries for every token; mounted
            // rows already have an O(1) index in the stable sequence.
            for id in Array(mounted.keys) {
                guard let cell = mounted[id],
                      let index = rowIndexByID[id],
                      oldSnapshot.rows.indices.contains(index),
                      newSnapshot.rows.indices.contains(index) else {
                    if let cell = mounted[id] { unmount(id: id, cell: cell) }
                    continue
                }
                let old = oldSnapshot.rows[index]
                let row = newSnapshot.rows[index]
                let nextKey = AppKitTranscriptRowReuseKey(row: row)
                if cell.key != nextKey
                    || old.contentIdentity != row.contentIdentity
                    || old.layoutIdentity != row.layoutIdentity {
                    unmount(id: id, cell: cell)
                }
            }
        } else {
            rowIndexByID = Dictionary(
                uniqueKeysWithValues: newSnapshot.rows.enumerated().map { ($0.element.id, $0.offset) }
            )
            let newRows = Dictionary(uniqueKeysWithValues: newSnapshot.rows.map { ($0.id, $0) })
            for id in Array(mounted.keys) {
                guard let cell = mounted[id], let row = newRows[id] else {
                    if let cell = mounted[id] { unmount(id: id, cell: cell) }
                    continue
                }
                if cell.key != AppKitTranscriptRowReuseKey(row: row) {
                    unmount(id: id, cell: cell)
                }
            }
        }

        if sameRowSequence {
            // Streaming normally changes only the live tail.  Keep the
            // Fenwick tree and apply each changed row as a point update
            // (O(log N)); rebuilding all prefixes on every token is the
            // long-session frame-time cliff this adapter is meant to avoid.
            for index in newSnapshot.rows.indices {
                let old = oldSnapshot.rows[index]
                let row = newSnapshot.rows[index]
                guard old.contentIdentity != row.contentIdentity
                        || old.layoutIdentity != row.layoutIdentity else { continue }
                let height = cachedHeightOrEstimate(row)
                if heightIndex.update(index: index, height: height) != 0 {
                    metrics.recordHeightIndexPointUpdate()
                }
            }
        } else {
            heightIndex.replace(with: newSnapshot.rows.map(cachedHeightOrEstimate))
            metrics.recordHeightIndexRebuild()
        }
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
        updateMountedFrames(repositionExisting: true, mountNewOverscanRows: false)
        scheduleOverscanRefill()
    }

    /// A clip-origin change does not alter document geometry.  Keep the hot
    /// wheel path to viewport mount/reposition work and reserve document-frame
    /// updates for snapshot, measurement, and resize operations.
    private func layoutViewportNow() {
        guard !layingOut else { return }
        layingOut = true
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            layingOut = false
            let duration = max(0, ProcessInfo.processInfo.systemUptime - started)
            metrics.recordLayout(duration: duration)
            metrics.recordSynchronousViewportWork(duration: duration)
        }
        if let coveredVisibleRowIDs = coveredVisibleRowIDs() {
            // Overscan hosts are already positioned in document coordinates;
            // moving the clip view reveals them without another SwiftUI
            // fitting pass. This is the common mouse-wheel hot path.
            immediatelyMeasuredVisibleRowIDs = coveredVisibleRowIDs
            reportVisibleRows()
            scheduleOverscanRefill()
            return
        }
        updateMountedFrames(repositionExisting: false, mountNewOverscanRows: false)
        scheduleOverscanRefill()
    }

    private func coveredVisibleRowIDs() -> Set<String>? {
        let viewport = scrollView.contentView.bounds
        let range = heightIndex.rows(
            intersecting: viewport.minY,
            viewportHeight: viewport.height,
            overscan: 0
        )
        var rowIDs: Set<String> = []
        rowIDs.reserveCapacity(range.count)
        for index in range where snapshot.rows.indices.contains(index) {
            let row = snapshot.rows[index]
            let rowID = row.id
            guard let cell = mounted[rowID],
                  !cell.host.isHidden,
                  !cell.host.needsImmediateContentMeasurement,
                  heightCache.value(for: layoutCacheKey(for: row)) != nil else { return nil }
            rowIDs.insert(rowID)
        }
        return rowIDs
    }

    /// Returns how many hosts were mounted by this pass. A deferred refill
    /// uses that value for bounded-work diagnostics and requeues itself when
    /// the current overscan window still has missing rows.
    @discardableResult
    private func updateMountedFrames(
        repositionExisting: Bool = true,
        mountNewOverscanRows: Bool = true,
        maximumNewMounts: Int? = nil,
        maximumDuration: TimeInterval? = nil,
        convergenceDepth: Int = 0
    ) -> Int {
        guard document != nil else { return 0 }
        let started = ProcessInfo.processInfo.systemUptime
        var mountedRows = 0
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
        let visibleIndices = Set(visibleRange)
        let visibleRowIDs = Set(visibleRange.compactMap { index in
            snapshot.rows.indices.contains(index) ? snapshot.rows[index].id : nil
        })
        var targetIndices = Array(overscanRange)
        if targetIndices.count > maximumMountedRows {
            let center = viewport.midY
            targetIndices = Array(targetIndices.sorted { lhs, rhs in
                let leftDistance = visibleIndices.contains(lhs) ? -1 : abs(heightIndex.offset(of: lhs) + (heightIndex.height(at: lhs) ?? 0) / 2 - center)
                let rightDistance = visibleIndices.contains(rhs) ? -1 : abs(heightIndex.offset(of: rhs) + (heightIndex.height(at: rhs) ?? 0) / 2 - center)
                return leftDistance < rightDistance
            }.prefix(maximumMountedRows)).sorted()
        }
        let targetIDs = Set(targetIndices.compactMap { index in
            snapshot.rows.indices.contains(index) ? snapshot.rows[index].id : nil
        })
        var newlyMountedVisibleHosts: [(rowID: String, host: AppKitTranscriptRowHost)] = []

        let staleIDs = mounted.keys.filter { !targetIDs.contains($0) }
        for id in staleIDs {
            if let cell = mounted[id] {
                unmount(id: id, cell: cell)
            }
        }

        for index in targetIndices where snapshot.rows.indices.contains(index) {
            if let maximumNewMounts, mountedRows >= maximumNewMounts {
                break
            }
            if let maximumDuration,
               mountedRows > 0,
               ProcessInfo.processInfo.systemUptime - started >= maximumDuration {
                break
            }
            let row = snapshot.rows[index]
            if !mountNewOverscanRows,
               !visibleIndices.contains(index),
               mounted[row.id] == nil {
                continue
            }
            let key = AppKitTranscriptRowReuseKey(row: row)
            if let cell = mounted[row.id] {
                if cell.key != key {
                    unmount(id: row.id, cell: cell)
                } else {
                    if repositionExisting {
                        position(cell.host, at: index)
                    }
                    if visibleIndices.contains(index),
                       (!immediatelyMeasuredVisibleRowIDs.contains(row.id)
                            || cell.host.needsImmediateContentMeasurement) {
                        newlyMountedVisibleHosts.append((rowID: row.id, host: cell.host))
                    }
                    continue
                }
            }
            let host: AppKitTranscriptRowHost
            let reused: Bool
            if let identityMatched = takeReusableHost(for: key) {
                host = identityMatched.host
                reused = true
                // An exact identity hit keeps the existing rich SwiftUI tree
                // intact. No root assignment or markdown parse occurs on the
                // scroll hot path; only the AppKit frame is updated below.
            } else if let pooled = takeOldestReusableHost() {
                host = pooled
                // A changed identity can still reuse the bounded cell. The
                // configure operation is isolated to this one visible row,
                // never to the rest of the transcript.
                host.configure(row: row, key: key)
                reused = true
            } else {
                host = rowFactory(row, key)
                reused = false
            }
            host.frame = NSRect(x: 0, y: heightIndex.offset(of: index), width: document.bounds.width, height: heightIndex.height(at: index) ?? 1)
            // Reusable cells stay attached to the document. Re-adding an
            // NSHostingView to a window rebuilds SwiftUI's FocusBridge and
            // the entire key-view loop, which shows up outside the measured
            // scroll callback as a dropped display frame.
            if host.superview !== document {
                document.addSubview(host)
            }
            host.isHidden = false
            mounted[row.id] = AppKitTranscriptMountedCell(key: key, host: host)
            metrics.recordMount(count: 1, peak: mounted.count, reused: reused)
            mountedRows += 1
            if visibleIndices.contains(index) {
                newlyMountedVisibleHosts.append((rowID: row.id, host: host))
            }
        }
        let visibleHeightsChanged = synchronouslyMeasureVisibleMounts(newlyMountedVisibleHosts)
        if visibleHeightsChanged, convergenceDepth < 4 {
            // A row that measured shorter than its estimate can expose rows
            // below the old visible range. Recompute and fill that range now;
            // cap convergence so pathological renderer feedback cannot turn a
            // viewport pass into unbounded recursive layout.
            mountedRows += updateMountedFrames(
                repositionExisting: true,
                mountNewOverscanRows: false,
                maximumNewMounts: nil,
                maximumDuration: nil,
                convergenceDepth: convergenceDepth + 1
            )
            return mountedRows
        }
        immediatelyMeasuredVisibleRowIDs = visibleRowIDs
        if repositionExisting {
            updateMountedFramesWithoutMounting()
        }
        reportVisibleRows()
        return mountedRows
    }

    private func scheduleOverscanRefill(after requestedDelay: TimeInterval? = nil) {
        guard !overscanRefillQueued else { return }
        overscanRefillQueued = true
        // A live wheel sequence owns the main-thread budget. Defer warm-cache
        // work until the gesture settles instead of competing with visible
        // row mounts on every packet.
        // For display-linked programmatic motion, fill one row in the quiet
        // part of the current frame. Waiting a full 16.7 ms aligns host
        // creation with the next VSync and can itself delay that callback.
        // Physical wheel input still defers all warm-cache work.
        let delay = max(0.004, requestedDelay ?? (isUserScrollActive ? 0.36 : 0.006))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.overscanRefillQueued = false
            guard !self.isUserScrollActive else {
                self.scheduleOverscanRefill(after: 0.36)
                return
            }
            let started = ProcessInfo.processInfo.systemUptime
            let mountedRows = self.updateMountedFrames(
                repositionExisting: false,
                mountNewOverscanRows: true,
                maximumNewMounts: self.maximumDeferredOverscanMountsPerPass,
                maximumDuration: self.maximumDeferredOverscanDuration
            )
            self.premeasureOneDeferredOverscanRow()
            let duration = max(0, ProcessInfo.processInfo.systemUptime - started)
            self.metrics.recordDeferredOverscanRefill(duration: duration, mountedRows: mountedRows)
            if self.hasMissingOverscanRows {
                self.scheduleOverscanRefill()
            }
        }
    }

    /// Warm one offscreen rich host while the wheel is idle. Creating an
    /// NSHostingView without resolving its intrinsic height merely moves the
    /// expensive layout to the first frame where the row becomes visible.
    /// The normal measured-height callback preserves the current anchor.
    private func premeasureOneDeferredOverscanRow() {
        guard !isUserScrollActive else { return }
        let viewport = scrollView.contentView.bounds
        guard let candidate = mounted.first(where: { _, cell in
            !cell.host.frame.intersects(viewport)
                && cell.host.needsImmediateContentMeasurement
        }) else { return }
        candidate.value.host.layoutSubtreeIfNeeded()
        let measured = candidate.value.host.preferredContentHeight
        guard measured.isFinite, measured > 0 else { return }
        _ = commitMeasuredHeight(rowID: candidate.key, height: measured)
    }

    private var hasMissingOverscanRows: Bool {
        let viewport = scrollView.contentView.bounds
        let range = heightIndex.rows(
            intersecting: viewport.minY,
            viewportHeight: viewport.height,
            overscan: overscan
        )
        var targetIndices = Array(range)
        if targetIndices.count > maximumMountedRows {
            let visibleRange = heightIndex.rows(
                intersecting: viewport.minY,
                viewportHeight: viewport.height,
                overscan: 0
            )
            let visibleIndices = Set(visibleRange)
            let center = viewport.midY
            targetIndices = Array(targetIndices.sorted { lhs, rhs in
                let leftDistance = visibleIndices.contains(lhs) ? -1 : abs(
                    heightIndex.offset(of: lhs)
                        + (heightIndex.height(at: lhs) ?? 0) / 2
                        - center
                )
                let rightDistance = visibleIndices.contains(rhs) ? -1 : abs(
                    heightIndex.offset(of: rhs)
                        + (heightIndex.height(at: rhs) ?? 0) / 2
                        - center
                )
                return leftDistance < rightDistance
            }.prefix(maximumMountedRows))
        }
        return targetIndices.contains { index in
            guard snapshot.rows.indices.contains(index) else { return false }
            guard let cell = mounted[snapshot.rows[index].id] else { return true }
            return cell.host.needsImmediateContentMeasurement
        }
    }

    private func updateMountedFramesWithoutMounting() {
        for (id, cell) in mounted {
            guard let index = rowIndexByID[id], snapshot.rows.indices.contains(index) else { continue }
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
        if maximumReusableHosts > 0 {
            // Keep the bounded reusable host attached but hidden. This avoids
            // viewDidMoveToWindow/FocusBridge work when the next row reuses it.
            cell.host.isHidden = true
            cacheReusableHost(cell.host, for: cell.key)
        } else {
            cell.host.removeFromSuperview()
            cell.host.prepareForReuse()
        }
        metrics.recordUnmount(count: 1)
    }

    private func takeReusableHost(
        for key: AppKitTranscriptRowReuseKey
    ) -> (host: AppKitTranscriptRowHost, exact: Bool)? {
        guard let host = reusableHostsByKey.removeValue(forKey: key) else { return nil }
        reusableHostLRU.removeAll { $0 == key }
        return (host, true)
    }

    private func takeOldestReusableHost() -> AppKitTranscriptRowHost? {
        while let key = reusableHostLRU.first {
            reusableHostLRU.removeFirst()
            if let host = reusableHostsByKey.removeValue(forKey: key) {
                return host
            }
        }
        // Recover safely if a future invalidation desynchronizes the LRU.
        // Attached hidden hosts must never be dropped from bookkeeping.
        if let (key, host) = reusableHostsByKey.first {
            reusableHostsByKey.removeValue(forKey: key)
            return host
        }
        return nil
    }

    private func cacheReusableHost(
        _ host: AppKitTranscriptRowHost,
        for key: AppKitTranscriptRowReuseKey
    ) {
        if let previous = reusableHostsByKey.updateValue(host, forKey: key), previous !== host {
            previous.removeFromSuperview()
            previous.prepareForReuse()
        }
        reusableHostLRU.removeAll { $0 == key }
        reusableHostLRU.append(key)
        while reusableHostLRU.count > maximumReusableHosts {
            let evictedKey = reusableHostLRU.removeFirst()
            guard let evicted = reusableHostsByKey.removeValue(forKey: evictedKey) else { continue }
            evicted.removeFromSuperview()
            evicted.prepareForReuse()
        }
    }

    private func reportVisibleRows() {
        let ids = Set(visibleHistoryTickIDs)
        guard ids != lastVisibleRowIDs else { return }
        lastVisibleRowIDs = ids
        guard !viewportReportQueued else { return }
        viewportReportQueued = true
        // The rail only needs settled visibility and should never mutate
        // SwiftUI state from inside an AppKit layout/update pass.  Physical
        // wheel input may arrive at 120 Hz; keep the rich viewport entirely
        // in AppKit and cap the auxiliary SwiftUI rail at the product's 60 Hz
        // contract, matching the previous observer path.
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastViewportReportUptime
        let delay = max(0, TranscriptViewportReportPolicy.minimumInterval - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.viewportReportQueued = false
            self.lastViewportReportUptime = ProcessInfo.processInfo.systemUptime
            NotificationCenter.default.post(
                name: Notification.Name("BubbleTranscriptViewportChanged"),
                object: self.scrollView,
                userInfo: [
                    "visibleRowIDs": self.visibleHistoryTickIDs
                ]
            )
        }
    }

    private func restore(_ anchor: TranscriptSurfaceAnchor) {
        guard let index = rowIndexByID[anchor.rowID], snapshot.rows.indices.contains(index) else { return }
        let next = heightIndex.offset(of: index) - anchor.offset
        setContentOffset(y: next)
    }

    private var isAtEnd: Bool {
        let maxY = max(0, heightIndex.totalHeight - scrollView.contentView.bounds.height)
        return abs(contentOffsetY - maxY) <= 1
    }

    private func cachedHeightOrEstimate(_ row: TranscriptRowSnapshot) -> CGFloat {
        heightCache.value(for: layoutCacheKey(for: row)) ?? row.estimatedHeight
    }

    private func layoutCacheKey(for row: TranscriptRowSnapshot) -> TranscriptLayoutCacheKey {
        var geometry = row.geometry
        // Disclosure is interaction-local and therefore does not mutate the
        // immutable row snapshot.  Include the live disclosure bit in the
        // cache key so a previously measured collapsed/expanded variant is
        // never reused for the other geometry.
        if interactionStore.isExpanded(rowID: row.id) {
            geometry = TranscriptLocalGeometryState(
                disclosure: max(1, geometry.disclosure),
                accessorySignature: geometry.accessorySignature
            )
        }
        return TranscriptLayoutCacheKey(
            rowID: row.id,
            contentVersion: row.contentVersion,
            contentHash: row.contentHash,
            width: CGFloat(widthBucket) / 2,
            typography: row.typography,
            scale: displayScale,
            geometry: geometry,
            layoutVersion: row.layoutVersion
        )
    }

    private var displayScale: CGFloat {
        let scale = scrollView.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        return scale.isFinite && scale > 0 ? scale : 1
    }

    private static func widthBucket(_ width: CGFloat) -> Int {
        Int((max(0, width) * 2).rounded(.toNearestOrAwayFromZero))
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
