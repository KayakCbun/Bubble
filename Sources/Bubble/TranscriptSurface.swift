import Foundation

/// A stable identity for one Bubble transcript runtime.  Generation changes
/// when Bubble starts a new main session; revisions advance for every accepted
/// surface update within that generation.
struct TranscriptSessionHandle: Equatable, Hashable, Sendable {
    let sessionID: String
    let generation: UInt64
    let revision: UInt64

    init(sessionID: String, generation: UInt64 = 0, revision: UInt64 = 0) {
        self.sessionID = sessionID
        self.generation = generation
        self.revision = revision
    }

    init(id: String, generation: UInt64 = 0, revision: UInt64 = 0) {
        self.init(sessionID: id, generation: generation, revision: revision)
    }

    init(sessionID: String, generation: Int, revision: Int) {
        self.init(
            sessionID: sessionID,
            generation: UInt64(max(0, generation)),
            revision: UInt64(max(0, revision))
        )
    }

    init(id: String, generation: Int, revision: Int) {
        self.init(sessionID: id, generation: generation, revision: revision)
    }

    /// Compatibility spelling for callers that model a handle as an id.
    var id: String { sessionID }

    func withRevision(_ nextRevision: UInt64) -> TranscriptSessionHandle {
        TranscriptSessionHandle(
            sessionID: sessionID,
            generation: generation,
            revision: nextRevision
        )
    }

    func nextRevision() -> TranscriptSessionHandle {
        withRevision(revision == UInt64.max ? revision : revision + 1)
    }

    func nextGeneration() -> TranscriptSessionHandle {
        TranscriptSessionHandle(
            sessionID: sessionID,
            generation: generation == UInt64.max ? generation : generation + 1,
            revision: 0
        )
    }

    /// Returns true only for a handle that can advance the same session.  A
    /// new generation is accepted even when its revision starts at zero.
    func accepts(_ candidate: TranscriptSessionHandle, allowingEqualRevision: Bool = false) -> Bool {
        guard sessionID == candidate.sessionID else { return false }
        if candidate.generation > generation { return true }
        guard candidate.generation == generation else { return false }
        return allowingEqualRevision ? candidate.revision >= revision : candidate.revision > revision
    }

    func isNewer(than other: TranscriptSessionHandle) -> Bool {
        guard sessionID == other.sessionID else { return false }
        return generation > other.generation
            || (generation == other.generation && revision > other.revision)
    }
}

enum TranscriptRowKind: String, Equatable, Hashable, Sendable {
    case user
    case assistant
    case system
    case tool
    case other
}

/// Immutable input to the transcript surface.  The body itself is owned by
/// the session store; the surface only needs a stable content hash and an
/// estimated height to decide what can be reused without reflowing history.
struct TranscriptRowSnapshot: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let contentVersion: UInt64
    let contentHash: String
    let estimatedHeight: CGFloat
    let isCompleted: Bool
    let kind: TranscriptRowKind
    let text: String?
    /// Owning user turn for history-rail visibility.  Assistant chunks,
    /// tools, and continuation rows map back to this stable tick identity.
    let historyTickID: String?
    /// Layout inputs travel with the immutable row projection.  They are
    /// deliberately separate from `contentIdentity`: changing width,
    /// typography, scale, or local disclosure geometry must invalidate a
    /// measured height without rebuilding an otherwise stable rich host.
    let typography: TranscriptTypographyKey
    let geometry: TranscriptLocalGeometryState
    let layoutVersion: UInt64

    init(
        id: String,
        contentVersion: UInt64 = 0,
        contentHash: String,
        estimatedHeight: CGFloat,
        isCompleted: Bool = true,
        kind: TranscriptRowKind = .other,
        text: String? = nil,
        historyTickID: String? = nil,
        typography: TranscriptTypographyKey = TranscriptTypographyKey.default,
        geometry: TranscriptLocalGeometryState = TranscriptLocalGeometryState(),
        layoutVersion: UInt64 = TranscriptTypographyKey.defaultLayoutVersion
    ) {
        self.id = id
        self.contentVersion = contentVersion
        self.contentHash = contentHash
        self.estimatedHeight = max(0, estimatedHeight.isFinite ? estimatedHeight : 0)
        self.isCompleted = isCompleted
        self.kind = kind
        self.text = text
        self.historyTickID = historyTickID
        self.typography = typography
        self.geometry = geometry
        self.layoutVersion = layoutVersion
    }

    init(
        id: String,
        contentVersion: Int,
        contentHash: String,
        estimatedHeight: CGFloat,
        isCompleted: Bool = true,
        kind: TranscriptRowKind = .other,
        text: String? = nil,
        historyTickID: String? = nil,
        typography: TranscriptTypographyKey = TranscriptTypographyKey.default,
        geometry: TranscriptLocalGeometryState = TranscriptLocalGeometryState(),
        layoutVersion: UInt64 = TranscriptTypographyKey.defaultLayoutVersion
    ) {
        self.init(
            id: id,
            contentVersion: UInt64(max(0, contentVersion)),
            contentHash: contentHash,
            estimatedHeight: estimatedHeight,
            isCompleted: isCompleted,
            kind: kind,
            text: text,
            historyTickID: historyTickID,
            typography: typography,
            geometry: geometry,
            layoutVersion: layoutVersion
        )
    }

    init(
        id: String,
        contentVersion: UInt64 = 0,
        text: String,
        estimatedHeight: CGFloat,
        isCompleted: Bool = true,
        kind: TranscriptRowKind = .other,
        historyTickID: String? = nil,
        typography: TranscriptTypographyKey = TranscriptTypographyKey.default,
        geometry: TranscriptLocalGeometryState = TranscriptLocalGeometryState(),
        layoutVersion: UInt64 = TranscriptTypographyKey.defaultLayoutVersion
    ) {
        self.init(
            id: id,
            contentVersion: contentVersion,
            contentHash: Self.stableHash(text),
            estimatedHeight: estimatedHeight,
            isCompleted: isCompleted,
            kind: kind,
            text: text,
            historyTickID: historyTickID,
            typography: typography,
            geometry: geometry,
            layoutVersion: layoutVersion
        )
    }

    var identity: TranscriptRowIdentity {
        TranscriptRowIdentity(
            id: id,
            contentVersion: contentVersion,
            contentHash: contentHash
        )
    }

    /// Content equality intentionally excludes estimated height.  Height is a
    /// layout estimate and may legitimately change with width or typography;
    /// it must not invalidate the immutable row render unit by itself.
    var contentIdentity: TranscriptRowIdentity { identity }

    var layoutIdentity: TranscriptRowLayoutIdentity {
        TranscriptRowLayoutIdentity(
            typography: typography,
            geometry: geometry,
            layoutVersion: layoutVersion
        )
    }

    static func stableHash(_ text: String) -> String {
        // FNV-1a is tiny, deterministic, and independent of Swift's process-
        // randomized Hasher seed, which makes persisted identities testable.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

struct TranscriptRowIdentity: Equatable, Hashable, Sendable {
    let id: String
    let contentVersion: UInt64
    let contentHash: String
}

struct TranscriptRowLayoutIdentity: Equatable, Hashable, Sendable {
    let typography: TranscriptTypographyKey
    let geometry: TranscriptLocalGeometryState
    let layoutVersion: UInt64

    static let `default` = TranscriptRowLayoutIdentity(
        typography: .default,
        geometry: TranscriptLocalGeometryState(),
        layoutVersion: TranscriptTypographyKey.defaultLayoutVersion
    )
}

struct TranscriptSurfaceAnchor: Equatable, Hashable, Sendable {
    let rowID: String
    let offset: CGFloat

    init(rowID: String, offset: CGFloat = 0) {
        self.rowID = rowID
        self.offset = offset.isFinite ? offset : 0
    }
}

enum TranscriptSurfaceAnchorPolicy: Equatable, Sendable {
    case preserve(TranscriptSurfaceAnchor)
    case keepViewport
    case followLatest
}

/// The only mutable state that belongs to interactions.  Disclosure is a
/// row-local concern; changing one row never creates a transcript-wide
/// invalidation set.
final class TranscriptInteractionStore {
    struct DisclosureChange: Equatable, Sendable {
        let rowID: String
        let oldValue: Bool
        let newValue: Bool

        var changed: Bool { oldValue != newValue }
    }

    private var disclosedRows: [String: Bool] = [:]

    init(disclosedRows: [String: Bool] = [:]) {
        self.disclosedRows = disclosedRows.filter { !$0.key.isEmpty }
    }

    func isExpanded(rowID: String) -> Bool {
        disclosedRows[rowID] ?? false
    }

    @discardableResult
    func setExpanded(_ expanded: Bool, for rowID: String) -> DisclosureChange {
        let oldValue = disclosedRows[rowID] ?? false
        if expanded {
            disclosedRows[rowID] = true
        } else {
            disclosedRows.removeValue(forKey: rowID)
        }
        return DisclosureChange(rowID: rowID, oldValue: oldValue, newValue: expanded)
    }

    func reset(rowID: String) {
        disclosedRows.removeValue(forKey: rowID)
    }

    func resetAll() {
        disclosedRows.removeAll(keepingCapacity: true)
    }

    var expandedRowIDs: Set<String> { Set(disclosedRows.compactMap { $0.value ? $0.key : nil }) }
}

/// Typography is represented by stable scalar values rather than a SwiftUI
/// Font.  That keeps cache keys usable by the model/rendering boundary and in
/// command-line deterministic checks.
struct TranscriptTypographyKey: Equatable, Hashable, Sendable {
    static let defaultLayoutVersion: UInt64 = 1
    static let `default` = TranscriptTypographyKey(
        fontFamily: ".AppleSystemUIFont",
        pointSize: 14,
        weight: 400,
        lineHeight: 1.625,
        styleID: "bubble-transcript-body"
    )

    let fontFamily: String
    let pointSize: Int
    let weight: Int
    let lineHeight: Int
    let styleID: String

    init(
        fontFamily: String,
        pointSize: CGFloat = 14,
        weight: Int = 400,
        lineHeight: CGFloat = 1.625,
        styleID: String = "body"
    ) {
        self.fontFamily = fontFamily
        self.pointSize = Self.quantize(pointSize)
        self.weight = weight
        self.lineHeight = Self.quantize(lineHeight)
        self.styleID = styleID
    }

    init(
        font: String,
        size: CGFloat = 14,
        weight: Int = 400,
        lineHeight: CGFloat = 1.625,
        style: String = "body"
    ) {
        self.init(
            fontFamily: font,
            pointSize: size,
            weight: weight,
            lineHeight: lineHeight,
            styleID: style
        )
    }

    private static func quantize(_ value: CGFloat) -> Int {
        Int((value.isFinite ? value : 0).rounded(.toNearestOrAwayFromZero) * 64)
    }
}

struct TranscriptLocalGeometryState: Equatable, Hashable, Sendable {
    let disclosure: Int
    let accessorySignature: String

    init(disclosure: Int = 0, accessorySignature: String = "") {
        self.disclosure = disclosure
        self.accessorySignature = accessorySignature
    }

    init(isExpanded: Bool, accessorySignature: String = "") {
        self.init(disclosure: isExpanded ? 1 : 0, accessorySignature: accessorySignature)
    }

    var isExpanded: Bool { disclosure != 0 }
}

/// Width and typography are part of the key because a completed row may wrap
/// differently after a side stage opens, a user changes text size, or a local
/// disclosure changes its geometry.
struct TranscriptLayoutCacheKey: Equatable, Hashable, Sendable {
    let rowID: String
    let contentVersion: UInt64
    let contentHash: String
    let quantizedWidth: Int
    let typography: TranscriptTypographyKey
    let quantizedScale: Int
    let geometry: TranscriptLocalGeometryState
    let layoutVersion: UInt64

    init(
        rowID: String,
        contentVersion: UInt64 = 0,
        contentHash: String,
        width: CGFloat,
        typography: TranscriptTypographyKey,
        scale: CGFloat = 1,
        geometry: TranscriptLocalGeometryState = TranscriptLocalGeometryState(),
        layoutVersion: UInt64 = TranscriptTypographyKey.defaultLayoutVersion
    ) {
        self.rowID = rowID
        self.contentVersion = contentVersion
        self.contentHash = contentHash
        self.quantizedWidth = Self.quantizeWidth(width)
        self.typography = typography
        self.quantizedScale = Self.quantize(scale)
        self.geometry = geometry
        self.layoutVersion = layoutVersion
    }

    init(
        rowID: String,
        contentHash: String,
        width: CGFloat,
        font: String,
        style: String,
        scale: CGFloat = 1,
        isExpanded: Bool = false,
        layoutVersion: UInt64 = TranscriptTypographyKey.defaultLayoutVersion
    ) {
        self.init(
            rowID: rowID,
            contentHash: contentHash,
            width: width,
            typography: TranscriptTypographyKey(font: font, style: style),
            scale: scale,
            geometry: TranscriptLocalGeometryState(isExpanded: isExpanded),
            layoutVersion: layoutVersion
        )
    }

    /// Widths are bucketed to half-point precision.  This suppresses AppKit
    /// sub-pixel geometry churn while allowing a 0.5pt wrap boundary to use a
    /// separate cached measurement.
    var width: CGFloat { CGFloat(quantizedWidth) / 2 }
    var scale: CGFloat { CGFloat(quantizedScale) / 64 }

    private static func quantize(_ value: CGFloat) -> Int {
        Int((value.isFinite ? value : 0).rounded(.toNearestOrAwayFromZero) * 64)
    }

    private static func quantizeWidth(_ value: CGFloat) -> Int {
        Int((value.isFinite ? value : 0).rounded(.toNearestOrAwayFromZero) * 2)
    }
}

/// Small LRU cache used by the render boundary.  It deliberately stores no
/// view objects, so it can be exercised from a deterministic Foundation-only
/// check and safely discarded when a new generation starts.
final class TranscriptHeightCache {
    let capacity: Int
    private var values: [TranscriptLayoutCacheKey: CGFloat] = [:]
    private var previous: [TranscriptLayoutCacheKey: TranscriptLayoutCacheKey] = [:]
    private var next: [TranscriptLayoutCacheKey: TranscriptLayoutCacheKey] = [:]
    private var oldest: TranscriptLayoutCacheKey?
    private var newest: TranscriptLayoutCacheKey?

    init(capacity: Int = 512) {
        self.capacity = max(0, capacity)
    }

    var count: Int { values.count }

    func value(for key: TranscriptLayoutCacheKey) -> CGFloat? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    func insert(_ height: CGFloat, for key: TranscriptLayoutCacheKey) {
        guard capacity > 0, height.isFinite, height >= 0 else { return }
        values[key] = height
        touch(key)
        while values.count > capacity, let evicted = oldest {
            removeValue(for: evicted)
        }
    }

    func removeValue(for key: TranscriptLayoutCacheKey) {
        values.removeValue(forKey: key)
        detach(key)
    }

    func removeAll() {
        values.removeAll(keepingCapacity: true)
        previous.removeAll(keepingCapacity: true)
        next.removeAll(keepingCapacity: true)
        oldest = nil
        newest = nil
    }

    private func touch(_ key: TranscriptLayoutCacheKey) {
        detach(key)
        if let newest {
            next[newest] = key
            previous[key] = newest
        } else {
            oldest = key
        }
        newest = key
    }

    private func detach(_ key: TranscriptLayoutCacheKey) {
        let older = previous.removeValue(forKey: key)
        let newer = next.removeValue(forKey: key)
        if let older {
            if let newer { next[older] = newer } else { next.removeValue(forKey: older) }
        } else if oldest == key {
            oldest = newer
        }
        if let newer {
            if let older { previous[newer] = older } else { previous.removeValue(forKey: newer) }
        } else if newest == key {
            newest = older
        }
    }
}

/// A tiny identity cache for expensive transcript projections.  SwiftUI may
/// evaluate an ancestor body for unrelated composer state; callers can keep
/// the immutable projection alive and only rebuild it when the explicit key
/// changes.  The counter is intentionally observable in focused checks so a
/// regression cannot silently reintroduce an O(N) projection on every keystroke.
final class TranscriptProjectionCache<Key: Equatable, Value> {
    private var cachedKey: Key?
    private var cachedValue: Value?
    private(set) var buildCount = 0

    init() {}

    func value(for key: Key, make: () -> Value) -> Value {
        if let cachedKey, cachedKey == key, let cachedValue {
            return cachedValue
        }
        let next = make()
        cachedKey = key
        cachedValue = next
        buildCount += 1
        return next
    }

    func reset() {
        cachedKey = nil
        cachedValue = nil
    }
}

struct TranscriptSurfaceSnapshot: Equatable, Sendable {
    let session: TranscriptSessionHandle
    /// Mutable only for the reducer's index-addressed streaming seam. Public
    /// callers still receive value snapshots; structural commands replace the
    /// array, while the hot path can update one live row without first making
    /// a temporary full-array copy.
    var rows: [TranscriptRowSnapshot]
    let anchor: TranscriptSurfaceAnchor?
    let followsLatest: Bool

    init(
        session: TranscriptSessionHandle,
        rows: [TranscriptRowSnapshot],
        anchor: TranscriptSurfaceAnchor? = nil,
        followsLatest: Bool = false
    ) {
        self.session = session
        self.rows = rows
        self.anchor = anchor
        self.followsLatest = followsLatest
    }

    var revision: UInt64 { session.revision }
    var generation: UInt64 { session.generation }
    var rowIDs: [String] { rows.map(\.id) }

    func row(id: String) -> TranscriptRowSnapshot? {
        rows.first { $0.id == id }
    }
}

/// A command carries the caller's session token.  The adapter accepts only a
/// strictly newer revision in the same generation, or a replacement from a
/// newer generation.  Anchor policy is explicit so a local interaction can
/// never accidentally request a transcript-wide follow-to-end.
struct TranscriptSurfaceCommand: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case replace(rows: [TranscriptRowSnapshot], followsLatest: Bool)
        case append(rows: [TranscriptRowSnapshot])
        case update(row: TranscriptRowSnapshot)
        case remove(rowIDs: [String])
        case disclose(rowID: String, expanded: Bool)
        case followLatest(animated: Bool)
        case setFollowLatest(Bool, animated: Bool)
        case scrollToEnd(animated: Bool)
        case reveal(rowID: String)
        case invalidate(rowIDs: [String])
    }

    let session: TranscriptSessionHandle
    let kind: Kind
    let anchorPolicy: TranscriptSurfaceAnchorPolicy

    init(
        session: TranscriptSessionHandle,
        kind: Kind,
        anchorPolicy: TranscriptSurfaceAnchorPolicy = .keepViewport
    ) {
        self.session = session
        self.kind = kind
        self.anchorPolicy = anchorPolicy
    }

    static func replace(
        snapshot: TranscriptSurfaceSnapshot,
        preserving anchor: TranscriptSurfaceAnchor? = nil
    ) -> TranscriptSurfaceCommand {
        TranscriptSurfaceCommand(
            session: snapshot.session,
            kind: .replace(rows: snapshot.rows, followsLatest: snapshot.followsLatest),
            // A producer snapshot may carry the anchor captured immediately
            // before a history prepend/replace.  Respect it by default;
            // callers can still override with an explicit `preserving:`
            // anchor when they have a fresher viewport observation.
            anchorPolicy: anchor.map(TranscriptSurfaceAnchorPolicy.preserve)
                ?? snapshot.anchor.map(TranscriptSurfaceAnchorPolicy.preserve)
                ?? .keepViewport
        )
    }

    static func append(
        rows: [TranscriptRowSnapshot],
        session: TranscriptSessionHandle,
        preserving anchor: TranscriptSurfaceAnchor? = nil
    ) -> TranscriptSurfaceCommand {
        TranscriptSurfaceCommand(
            session: session,
            kind: .append(rows: rows),
            anchorPolicy: anchor.map(TranscriptSurfaceAnchorPolicy.preserve) ?? .keepViewport
        )
    }

    static func update(
        row: TranscriptRowSnapshot,
        session: TranscriptSessionHandle,
        preserving anchor: TranscriptSurfaceAnchor? = nil
    ) -> TranscriptSurfaceCommand {
        TranscriptSurfaceCommand(
            session: session,
            kind: .update(row: row),
            anchorPolicy: anchor.map(TranscriptSurfaceAnchorPolicy.preserve) ?? .keepViewport
        )
    }

    static func disclose(
        rowID: String,
        expanded: Bool,
        session: TranscriptSessionHandle,
        preserving anchor: TranscriptSurfaceAnchor? = nil
    ) -> TranscriptSurfaceCommand {
        TranscriptSurfaceCommand(
            session: session,
            kind: .disclose(rowID: rowID, expanded: expanded),
            anchorPolicy: anchor.map(TranscriptSurfaceAnchorPolicy.preserve) ?? .keepViewport
        )
    }

    static func followLatest(
        session: TranscriptSessionHandle,
        animated: Bool = false
    ) -> TranscriptSurfaceCommand {
        TranscriptSurfaceCommand(
            session: session,
            kind: .followLatest(animated: animated),
            anchorPolicy: .followLatest
        )
    }

    static func setFollowLatest(
        _ followsLatest: Bool,
        session: TranscriptSessionHandle,
        animated: Bool = false,
        preserving anchor: TranscriptSurfaceAnchor? = nil
    ) -> TranscriptSurfaceCommand {
        TranscriptSurfaceCommand(
            session: session,
            kind: .setFollowLatest(followsLatest, animated: animated),
            anchorPolicy: followsLatest
                ? .followLatest
                : (anchor.map(TranscriptSurfaceAnchorPolicy.preserve) ?? .keepViewport)
        )
    }

    static func scrollToEnd(
        session: TranscriptSessionHandle,
        animated: Bool = false
    ) -> TranscriptSurfaceCommand {
        TranscriptSurfaceCommand(
            session: session,
            kind: .scrollToEnd(animated: animated),
            anchorPolicy: .followLatest
        )
    }

    static func reveal(
        rowID: String,
        session: TranscriptSessionHandle,
        preserving anchor: TranscriptSurfaceAnchor? = nil
    ) -> TranscriptSurfaceCommand {
        TranscriptSurfaceCommand(
            session: session,
            kind: .reveal(rowID: rowID),
            anchorPolicy: anchor.map(TranscriptSurfaceAnchorPolicy.preserve) ?? .keepViewport
        )
    }

    static func invalidate(
        rowIDs: [String],
        session: TranscriptSessionHandle,
        preserving anchor: TranscriptSurfaceAnchor? = nil
    ) -> TranscriptSurfaceCommand {
        TranscriptSurfaceCommand(
            session: session,
            kind: .invalidate(rowIDs: rowIDs),
            anchorPolicy: anchor.map(TranscriptSurfaceAnchorPolicy.preserve) ?? .keepViewport
        )
    }
}

enum TranscriptSurfaceEvent: Equatable, Sendable {
    case snapshotApplied(
        session: TranscriptSessionHandle,
        reusedRowIDs: [String],
        invalidatedRowIDs: [String],
        anchor: TranscriptSurfaceAnchor?
    )
    case rowDisclosureChanged(
        session: TranscriptSessionHandle,
        rowID: String,
        expanded: Bool,
        invalidatedRowIDs: [String],
        anchor: TranscriptSurfaceAnchor?
    )
    case followLatestRequested(session: TranscriptSessionHandle, animated: Bool)
    case followLatestChanged(session: TranscriptSessionHandle, followsLatest: Bool, animated: Bool)
    case scrollToEndRequested(session: TranscriptSessionHandle, animated: Bool)
    case rowRevealRequested(session: TranscriptSessionHandle, rowID: String, anchor: TranscriptSurfaceAnchor?)
    case rowsInvalidated(session: TranscriptSessionHandle, rowIDs: [String], anchor: TranscriptSurfaceAnchor?)
    case anchorPreserved(TranscriptSurfaceAnchor)
    case completedRowMutationRejected(rowID: String)
    case rowNotFound(rowID: String)
    case staleGenerationIgnored(
        current: TranscriptSessionHandle,
        received: TranscriptSessionHandle
    )
    case staleRevisionIgnored(
        current: TranscriptSessionHandle,
        received: TranscriptSessionHandle
    )
}

protocol TranscriptSurfaceAdapter: AnyObject {
    var snapshot: TranscriptSurfaceSnapshot { get }

    @discardableResult
    func apply(_ command: TranscriptSurfaceCommand) -> [TranscriptSurfaceEvent]

    @discardableResult
    func perform(_ command: TranscriptSurfaceCommand) -> [TranscriptSurfaceEvent]
}

/// The non-recording state reducer used by the production AppKit surface.
/// Keeping it free of command/event history is important: a streamed turn can
/// produce thousands of replacements and must not retain O(revisions × rows)
/// memory merely because it is rendered in the UI.
final class TranscriptSurfaceState: TranscriptSurfaceAdapter {
    private(set) var snapshot: TranscriptSurfaceSnapshot
    let interactionStore: TranscriptInteractionStore
    let heightCache: TranscriptHeightCache
    private var rowIndexByID: [String: Int]

    init(
        snapshot: TranscriptSurfaceSnapshot? = nil,
        interactionStore: TranscriptInteractionStore = TranscriptInteractionStore(),
        heightCache: TranscriptHeightCache = TranscriptHeightCache()
    ) {
        self.snapshot = snapshot ?? TranscriptSurfaceSnapshot(
            session: TranscriptSessionHandle(sessionID: "main"),
            rows: []
        )
        self.interactionStore = interactionStore
        self.heightCache = heightCache
        self.rowIndexByID = Dictionary(
            uniqueKeysWithValues: self.snapshot.rows.enumerated().map { ($0.element.id, $0.offset) }
        )
    }

    var currentHandle: TranscriptSessionHandle { snapshot.session }

    /// Returns one row without exposing the backing array. AppKit's streaming
    /// adapter uses this seam to capture the previous tail value before an
    /// index-addressed update, avoiding a snapshot/array copy of the complete
    /// transcript.
    func row(at index: Int) -> TranscriptRowSnapshot? {
        guard snapshot.rows.indices.contains(index) else { return nil }
        return snapshot.rows[index]
    }

    func nextCommandHandle() -> TranscriptSessionHandle { currentHandle.nextRevision() }

    @discardableResult
    func apply(_ command: TranscriptSurfaceCommand) -> [TranscriptSurfaceEvent] {
        applyCommand(command)
    }

    @discardableResult
    func perform(_ command: TranscriptSurfaceCommand) -> [TranscriptSurfaceEvent] {
        apply(command)
    }

    private func applyCommand(_ command: TranscriptSurfaceCommand) -> [TranscriptSurfaceEvent] {
        guard command.session.sessionID == snapshot.session.sessionID else {
            return [
                .staleGenerationIgnored(current: snapshot.session, received: command.session)
            ]
        }

        let isGenerationAdvance = command.session.generation > snapshot.session.generation
        let isPristineReplacement = snapshot.rows.isEmpty
            && command.session == snapshot.session
            && isReplace(command.kind)
        // Generation is the outer ordering boundary.  A stale generation must
        // never sneak through merely because it carries a larger revision.
        guard command.session.generation >= snapshot.session.generation else {
            return [
                .staleGenerationIgnored(current: snapshot.session, received: command.session)
            ]
        }
        guard isGenerationAdvance
                || command.session.revision > snapshot.session.revision
                || isPristineReplacement else {
            return [
                .staleRevisionIgnored(current: snapshot.session, received: command.session)
            ]
        }

        if isGenerationAdvance, !isReplace(command.kind) {
            return [
                .staleGenerationIgnored(current: snapshot.session, received: command.session)
            ]
        }

        switch command.kind {
        case let .replace(rows, followsLatest):
            return replace(
                rows: rows,
                followsLatest: followsLatest,
                session: command.session,
                anchorPolicy: command.anchorPolicy
            )
        case let .append(rows):
            return append(
                rows: rows,
                session: command.session,
                anchorPolicy: command.anchorPolicy
            )
        case let .update(row):
            return update(
                row: row,
                session: command.session,
                anchorPolicy: command.anchorPolicy
            )
        case let .remove(rowIDs):
            return remove(
                rowIDs: rowIDs,
                session: command.session,
                anchorPolicy: command.anchorPolicy
            )
        case let .disclose(rowID, expanded):
            return disclose(
                rowID: rowID,
                expanded: expanded,
                session: command.session,
                anchorPolicy: command.anchorPolicy
            )
        case let .followLatest(animated):
            snapshot = TranscriptSurfaceSnapshot(
                session: command.session,
                rows: snapshot.rows,
                anchor: nil,
                followsLatest: true
            )
            return [.followLatestRequested(session: command.session, animated: animated)]
        case let .setFollowLatest(followsLatest, animated):
            let anchor = followsLatest ? nil : resolvedAnchor(command.anchorPolicy)
            snapshot = TranscriptSurfaceSnapshot(
                session: command.session,
                rows: snapshot.rows,
                anchor: anchor,
                followsLatest: followsLatest
            )
            return [
                .followLatestChanged(
                    session: command.session,
                    followsLatest: followsLatest,
                    animated: animated
                )
            ]
        case let .scrollToEnd(animated):
            snapshot = TranscriptSurfaceSnapshot(
                session: command.session,
                rows: snapshot.rows,
                anchor: nil,
                followsLatest: true
            )
            return [.scrollToEndRequested(session: command.session, animated: animated)]
        case let .reveal(rowID):
            guard snapshot.row(id: rowID) != nil else {
                return [.rowNotFound(rowID: rowID)]
            }
            let anchor = resolvedAnchor(command.anchorPolicy)
            snapshot = TranscriptSurfaceSnapshot(
                session: command.session,
                rows: snapshot.rows,
                anchor: anchor,
                followsLatest: snapshot.followsLatest
            )
            var events: [TranscriptSurfaceEvent] = [
                .rowRevealRequested(session: command.session, rowID: rowID, anchor: anchor)
            ]
            if let anchor { events.append(.anchorPreserved(anchor)) }
            return events
        case let .invalidate(rowIDs):
            let anchor = resolvedAnchor(command.anchorPolicy)
            snapshot = TranscriptSurfaceSnapshot(
                session: command.session,
                rows: snapshot.rows,
                anchor: anchor,
                followsLatest: snapshot.followsLatest
            )
            var events: [TranscriptSurfaceEvent] = [
                .rowsInvalidated(
                    session: command.session,
                    rowIDs: Array(Set(rowIDs)).sorted(),
                    anchor: anchor
                )
            ]
            if let anchor { events.append(.anchorPreserved(anchor)) }
            return events
        }
    }

    private func replace(
        rows incomingRows: [TranscriptRowSnapshot],
        followsLatest: Bool,
        session: TranscriptSessionHandle,
        anchorPolicy: TranscriptSurfaceAnchorPolicy
    ) -> [TranscriptSurfaceEvent] {
        let normalized = normalizeCompletedRows(incomingRows)
        let oldByID = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: normalized.rows.map { ($0.id, $0) })
        let reused = normalized.rows.compactMap { row -> String? in
            guard let old = oldByID[row.id], old.contentIdentity == row.contentIdentity else {
                return nil
            }
            return row.id
        }
        let invalidated = normalized.rows.compactMap { row -> String? in
            guard let old = oldByID[row.id] else { return row.id }
            return old.contentIdentity == row.contentIdentity ? nil : row.id
        }
        let anchor = resolvedAnchor(anchorPolicy)
        snapshot = TranscriptSurfaceSnapshot(
            session: session,
            rows: normalized.rows,
            anchor: anchor,
            followsLatest: followsLatest
        )
        rebuildRowIndex()
        var events: [TranscriptSurfaceEvent] = [
            .snapshotApplied(
                session: session,
                reusedRowIDs: reused.sorted(),
                invalidatedRowIDs: invalidated.sorted(),
                anchor: anchor
            )
        ]
        events.append(contentsOf: normalized.rejections.map { .completedRowMutationRejected(rowID: $0) })
        if let anchor, anchorPolicy != .followLatest {
            events.append(.anchorPreserved(anchor))
        }
        _ = newByID // Keep the duplicate-id precondition explicit for future adapters.
        return events
    }

    private func append(
        rows incomingRows: [TranscriptRowSnapshot],
        session: TranscriptSessionHandle,
        anchorPolicy: TranscriptSurfaceAnchorPolicy
    ) -> [TranscriptSurfaceEvent] {
        let normalized = normalizeCompletedRows(incomingRows)
        var rows = snapshot.rows
        var reused: [String] = []
        var invalidated: [String] = []
        var rejections = normalized.rejections
        for row in normalized.rows {
            if let index = rows.firstIndex(where: { $0.id == row.id }) {
                let old = rows[index]
                if old.isCompleted && old.contentIdentity != row.contentIdentity {
                    rejections.append(row.id)
                    reused.append(row.id)
                } else if old.contentIdentity == row.contentIdentity {
                    reused.append(row.id)
                } else {
                    rows[index] = row
                    invalidated.append(row.id)
                }
            } else {
                rows.append(row)
                invalidated.append(row.id)
            }
        }
        let anchor = resolvedAnchor(anchorPolicy)
        snapshot = TranscriptSurfaceSnapshot(
            session: session,
            rows: rows,
            anchor: anchor,
            followsLatest: snapshot.followsLatest
        )
        rebuildRowIndex()
        var events: [TranscriptSurfaceEvent] = [
            .snapshotApplied(
                session: session,
                reusedRowIDs: reused.sorted(),
                invalidatedRowIDs: invalidated.sorted(),
                anchor: anchor
            )
        ]
        events.append(contentsOf: rejections.map { .completedRowMutationRejected(rowID: $0) })
        if let anchor, anchorPolicy != .followLatest {
            events.append(.anchorPreserved(anchor))
        }
        return events
    }

    private func update(
        row: TranscriptRowSnapshot,
        session: TranscriptSessionHandle,
        anchorPolicy: TranscriptSurfaceAnchorPolicy
    ) -> [TranscriptSurfaceEvent] {
        guard let index = rowIndexByID[row.id] else {
            return [.rowNotFound(rowID: row.id)]
        }
        let old = snapshot.rows[index]
        if old.isCompleted && old.contentIdentity != row.contentIdentity {
            snapshot = TranscriptSurfaceSnapshot(
                session: session,
                rows: snapshot.rows,
                anchor: resolvedAnchor(anchorPolicy),
                followsLatest: snapshot.followsLatest
            )
            return [.completedRowMutationRejected(rowID: row.id)]
        }
        if old == row {
            snapshot = TranscriptSurfaceSnapshot(
                session: session,
                rows: snapshot.rows,
                anchor: resolvedAnchor(anchorPolicy),
                followsLatest: snapshot.followsLatest
            )
            return [
                .snapshotApplied(
                    session: session,
                    reusedRowIDs: [row.id],
                    invalidatedRowIDs: [],
                    anchor: resolvedAnchor(anchorPolicy)
                )
            ]
        }
        // Mutate the live snapshot buffer at its known index. Keeping the
        // write here (rather than copying `snapshot.rows` into a temporary)
        // is what allows AppKit's index-addressed streaming path to avoid an
        // O(N) Array copy for every token. Structural commands still replace
        // the whole buffer through their cold paths above.
        snapshot.rows[index] = row
        let anchor = resolvedAnchor(anchorPolicy)
        snapshot = TranscriptSurfaceSnapshot(
            session: session,
            rows: snapshot.rows,
            anchor: anchor,
            followsLatest: snapshot.followsLatest
        )
        return [
            .snapshotApplied(
                session: session,
                reusedRowIDs: [],
                invalidatedRowIDs: [row.id],
                anchor: anchor
            )
        ]
    }

    private func remove(
        rowIDs: [String],
        session: TranscriptSessionHandle,
        anchorPolicy: TranscriptSurfaceAnchorPolicy
    ) -> [TranscriptSurfaceEvent] {
        let ids = Set(rowIDs)
        let rows = snapshot.rows.filter { !ids.contains($0.id) }
        let anchor = resolvedAnchor(anchorPolicy)
        snapshot = TranscriptSurfaceSnapshot(
            session: session,
            rows: rows,
            anchor: anchor,
            followsLatest: snapshot.followsLatest
        )
        rebuildRowIndex()
        return [
            .snapshotApplied(
                session: session,
                reusedRowIDs: rows.map(\.id).sorted(),
                invalidatedRowIDs: [],
                anchor: anchor
            )
        ]
    }

    private func disclose(
        rowID: String,
        expanded: Bool,
        session: TranscriptSessionHandle,
        anchorPolicy: TranscriptSurfaceAnchorPolicy
    ) -> [TranscriptSurfaceEvent] {
        guard snapshot.row(id: rowID) != nil else {
            return [.rowNotFound(rowID: rowID)]
        }
        let change = interactionStore.setExpanded(expanded, for: rowID)
        let anchor = resolvedAnchor(anchorPolicy)
        snapshot = TranscriptSurfaceSnapshot(
            session: session,
            rows: snapshot.rows,
            anchor: anchor,
            followsLatest: snapshot.followsLatest
        )
        guard change.changed else {
            return [
                .rowDisclosureChanged(
                    session: session,
                    rowID: rowID,
                    expanded: expanded,
                    invalidatedRowIDs: [],
                    anchor: anchor
                )
            ]
        }
        var events: [TranscriptSurfaceEvent] = [
            .rowDisclosureChanged(
                session: session,
                rowID: rowID,
                expanded: expanded,
                invalidatedRowIDs: [rowID],
                anchor: anchor
            )
        ]
        if let anchor {
            events.append(.anchorPreserved(anchor))
        }
        return events
    }

    private func resolvedAnchor(_ policy: TranscriptSurfaceAnchorPolicy) -> TranscriptSurfaceAnchor? {
        switch policy {
        case let .preserve(anchor):
            return anchor
        case .keepViewport:
            return snapshot.anchor
        case .followLatest:
            return nil
        }
    }

    private func rebuildRowIndex() {
        rowIndexByID = Dictionary(
            uniqueKeysWithValues: snapshot.rows.enumerated().map { ($0.element.id, $0.offset) }
        )
    }

    private func normalizeCompletedRows(
        _ incomingRows: [TranscriptRowSnapshot]
    ) -> (rows: [TranscriptRowSnapshot], rejections: [String]) {
        var rows: [TranscriptRowSnapshot] = []
        rows.reserveCapacity(incomingRows.count)
        var rejections: [String] = []
        let existing = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.id, $0) })
        var seen: Set<String> = []
        for row in incomingRows where seen.insert(row.id).inserted {
            if let old = existing[row.id], old.isCompleted, old.contentIdentity != row.contentIdentity {
                rows.append(old)
                rejections.append(row.id)
            } else {
                rows.append(row)
            }
        }
        return (rows, rejections)
    }

    private func isReplace(_ kind: TranscriptSurfaceCommand.Kind) -> Bool {
        if case .replace = kind { return true }
        return false
    }
}

/// Recording remains available for deterministic Foundation-only checks, but
/// production adapters should use `TranscriptSurfaceState` directly.  The
/// wrapper owns only the bounded test history and forwards state operations.
final class RecordingTranscriptSurfaceAdapter: TranscriptSurfaceAdapter {
    private let state: TranscriptSurfaceState
    private(set) var recordedCommands: [TranscriptSurfaceCommand] = []
    private(set) var recordedEvents: [TranscriptSurfaceEvent] = []

    init(
        snapshot: TranscriptSurfaceSnapshot? = nil,
        interactionStore: TranscriptInteractionStore = TranscriptInteractionStore(),
        heightCache: TranscriptHeightCache = TranscriptHeightCache()
    ) {
        state = TranscriptSurfaceState(
            snapshot: snapshot,
            interactionStore: interactionStore,
            heightCache: heightCache
        )
    }

    var snapshot: TranscriptSurfaceSnapshot { state.snapshot }
    var interactionStore: TranscriptInteractionStore { state.interactionStore }
    var heightCache: TranscriptHeightCache { state.heightCache }
    var currentHandle: TranscriptSessionHandle { state.currentHandle }
    func nextCommandHandle() -> TranscriptSessionHandle { currentHandle.nextRevision() }

    @discardableResult
    func apply(_ command: TranscriptSurfaceCommand) -> [TranscriptSurfaceEvent] {
        let events = state.apply(command)
        recordedCommands.append(command)
        recordedEvents.append(contentsOf: events)
        return events
    }

    @discardableResult
    func perform(_ command: TranscriptSurfaceCommand) -> [TranscriptSurfaceEvent] {
        apply(command)
    }
}
