import Foundation

enum TranscriptVirtualizationLimits {
    /// Enough room for hundreds of rich turns while the view layer keeps only
    /// visible rows alive. This is a persistence guard, not a render window.
    static let retainedItems = 4_000
}

enum TranscriptChunkRenderPolicy {
    static func sourceText(_ sourceText: String, isChunked: Bool) -> String {
        isChunked ? "" : sourceText
    }

    static func sourceIsLive(
        sourceIsLive: Bool,
        isChunked: Bool,
        isStreaming: Bool,
        isTerminal: Bool
    ) -> Bool {
        isChunked ? isStreaming && isTerminal : sourceIsLive
    }
}

struct TranscriptRenderSeed: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case user
        case assistant
        case other
    }

    var id: String
    var kind: Kind
    var text: String
    var sourceIDs: Set<String>
    var hasMedia: Bool

    init(id: String, kind: Kind, text: String, sourceIDs: Set<String> = [], hasMedia: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.sourceIDs = sourceIDs
        self.hasMedia = hasMedia
    }
}

struct TranscriptRenderUnit: Identifiable, Equatable, Sendable {
    var id: String
    var seedIndex: Int
    var kind: TranscriptRenderSeed.Kind
    var text: String
    var copyText: String?
    var isContinuation: Bool
    var isChunked: Bool
    var isTerminal: Bool
    var isStreaming: Bool
    var isAfterBranchPoint: Bool
    var startsAfterBranchPoint: Bool
}

struct TranscriptRenderPlan: Equatable, Sendable {
    var units: [TranscriptRenderUnit]
    var branchSeedIndex: Int?

    static func build(
        seeds: [TranscriptRenderSeed],
        branchSourceID: String?,
        streamingSeedIDs: Set<String>
    ) -> TranscriptRenderPlan {
        build(
            seeds: seeds,
            branchSourceID: branchSourceID,
            templates: seeds.map {
                templates(for: $0, streaming: streamingSeedIDs.contains($0.id))
            }
        )
    }

    fileprivate static func build(
        seeds: [TranscriptRenderSeed],
        branchSourceID: String?,
        templates: [[TranscriptRenderTemplate]]
    ) -> TranscriptRenderPlan {
        let branchSeedIndex = branchSourceID.flatMap { sourceID in
            seeds.firstIndex { $0.sourceIDs.contains(sourceID) }
        }
        var units: [TranscriptRenderUnit] = []
        units.reserveCapacity(templates.reduce(into: 0) { $0 += $1.count })

        for (seedIndex, seed) in seeds.enumerated() {
            units.append(contentsOf: Self.units(
                for: seed,
                seedIndex: seedIndex,
                branchSeedIndex: branchSeedIndex,
                templates: templates[seedIndex]
            ))
        }

        return TranscriptRenderPlan(units: units, branchSeedIndex: branchSeedIndex)
    }

    /// Materializes one source seed into its virtual rows.  Keeping this
    /// seam private-to-the-module lets the incremental planner replace only a
    /// changed streaming seed while preserving every completed unit object.
    fileprivate static func units(
        for seed: TranscriptRenderSeed,
        seedIndex: Int,
        branchSeedIndex: Int?,
        templates: [TranscriptRenderTemplate]
    ) -> [TranscriptRenderUnit] {
        let isAfterBranchPoint = branchSeedIndex.map { seedIndex > $0 } ?? false
        let startsAfterBranchPoint = branchSeedIndex.map { seedIndex == $0 + 1 } ?? false
        return templates.map { template in
            TranscriptRenderUnit(
                id: template.id,
                seedIndex: seedIndex,
                kind: seed.kind,
                text: template.text,
                copyText: template.copyText,
                isContinuation: template.isContinuation,
                isChunked: template.isChunked,
                isTerminal: template.isTerminal,
                isStreaming: template.isStreaming,
                isAfterBranchPoint: isAfterBranchPoint,
                startsAfterBranchPoint: startsAfterBranchPoint && !template.isContinuation
            )
        }
    }

    fileprivate static func templates(
        for seed: TranscriptRenderSeed,
        streaming: Bool
    ) -> [TranscriptRenderTemplate] {
        // Paragraph-local assistant prose is safe to split while it streams.
        // Existing chunk identities stay put as the tail grows, so SwiftUI only
        // has to remeasure the live tail instead of one ever-growing row.
        let chunks = seed.kind == .assistant && !seed.hasMedia
            ? WorkspaceTranscriptChunker.chunks(seed.text, identity: seed.id)
            : [seed.text]
        return chunks.enumerated().map { chunkIndex, text in
            let isLast = chunkIndex == chunks.count - 1
            return TranscriptRenderTemplate(
                id: chunkIndex == 0 ? seed.id : "\(seed.id)-chunk-\(chunkIndex)",
                text: text,
                copyText: chunks.count > 1 && isLast && !streaming ? seed.text : nil,
                isContinuation: chunkIndex > 0,
                isChunked: chunks.count > 1,
                isTerminal: isLast,
                isStreaming: streaming
            )
        }
    }
}

private struct TranscriptRenderTemplate {
    var id: String
    var text: String
    var copyText: String?
    var isContinuation: Bool
    var isChunked: Bool
    var isTerminal: Bool
    var isStreaming: Bool
}

/// Work performed by the planner for the most recent request.  This is
/// intentionally a value type so diagnostics and focused checks can assert
/// that a long immutable prefix was reused rather than merely timing a fast
/// machine.  `inspectedSeedCount` counts cheap identity checks (ids/kinds),
/// not full source-text comparisons.
struct TranscriptRenderPlannerWork: Equatable, Sendable {
    enum Mode: String, Sendable {
        case cold
        case cached
        case incremental
        case rebuilt
    }

    var mode: Mode = .cold
    var inspectedSeedCount = 0
    var rebuiltSeedCount = 0
    var rebuiltUnitCount = 0
    var reusedUnitCount = 0
    var planUnitCount = 0
}

/// Keeps the row and chunk plan stable across unrelated SwiftUI updates. The
/// per-seed cache means a streaming tail rebuilds only its own render unit;
/// completed history reuses the same chunk strings and identities.
final class TranscriptRenderPlanner {
    private struct CachedSeed {
        var seed: TranscriptRenderSeed
        var streaming: Bool
        var templates: [TranscriptRenderTemplate]
        var units: [TranscriptRenderUnit]
    }

    private var cachedSeeds: [CachedSeed] = []
    private var cachedBranchSourceID: String?
    private var cachedStreamingSeedIDs: Set<String> = []
    private var cachedPlan = TranscriptRenderPlan(units: [], branchSeedIndex: nil)
    private var seedCache: [String: CachedSeed] = [:]
    private var cachedUnitRanges: [Range<Int>] = []

    private(set) var lastWork = TranscriptRenderPlannerWork()

    func plan(
        seeds: [TranscriptRenderSeed],
        branchSourceID: String?,
        streamingSeedIDs: Set<String>
    ) -> TranscriptRenderPlan {
        guard !cachedSeeds.isEmpty else {
            return rebuild(
                seeds: seeds,
                branchSourceID: branchSourceID,
                streamingSeedIDs: streamingSeedIDs,
                mode: .cold
            )
        }

        // A branch switch, prepend, or append changes seed indexes and thus
        // changes the meaning of every flattened unit.  Rebuild the plan in
        // that case, but still reuse unchanged per-seed templates below.
        guard branchSourceID == cachedBranchSourceID,
              structureMatches(seeds) else {
            return rebuild(
                seeds: seeds,
                branchSourceID: branchSourceID,
                streamingSeedIDs: streamingSeedIDs,
                mode: .rebuilt
            )
        }

        // When no stream is active we need exact text validation because tool
        // and system rows may be edited in place.  This path is not on the
        // token-by-token hot path; the active-stream path below never compares
        // the full seed array or completed source text.
        if streamingSeedIDs.isEmpty, cachedStreamingSeedIDs.isEmpty {
            guard seeds.indices.allSatisfy({ seeds[$0] == cachedSeeds[$0].seed }) else {
                return rebuild(
                    seeds: seeds,
                    branchSourceID: branchSourceID,
                    streamingSeedIDs: streamingSeedIDs,
                    mode: .rebuilt
                )
            }
            lastWork = TranscriptRenderPlannerWork(
                mode: .cached,
                inspectedSeedCount: seeds.count,
                rebuiltSeedCount: 0,
                rebuiltUnitCount: 0,
                reusedUnitCount: cachedPlan.units.count,
                planUnitCount: cachedPlan.units.count
            )
            return cachedPlan
        }

        return incrementalPlan(
            seeds: seeds,
            branchSourceID: branchSourceID,
            streamingSeedIDs: streamingSeedIDs
        ) ?? rebuild(
            seeds: seeds,
            branchSourceID: branchSourceID,
            streamingSeedIDs: streamingSeedIDs,
            mode: .rebuilt
        )
    }

    /// Applies a stream update by replacing only the flattened ranges owned
    /// by the affected seed ids.  The completed prefix is never rematerialized
    /// and the only full-text equality check is for the active tail itself.
    private func incrementalPlan(
        seeds: [TranscriptRenderSeed],
        branchSourceID: String?,
        streamingSeedIDs: Set<String>
    ) -> TranscriptRenderPlan? {
        let statusChangedIDs = cachedStreamingSeedIDs.symmetricDifference(streamingSeedIDs)
        let candidateIDs = cachedStreamingSeedIDs.union(streamingSeedIDs)
        guard !candidateIDs.isEmpty,
              candidateIDs.allSatisfy({ id in cachedSeeds.contains { $0.seed.id == id } }) else {
            return nil
        }

        let candidateIndices = candidateIDs.compactMap { id in
            seeds.firstIndex { $0.id == id }
        }
        guard candidateIndices.count == candidateIDs.count else {
            // An active stream id disappearing from the source array is a
            // structural edit (usually a session restore or branch switch).
            return nil
        }

        // Completed history normally shares the same String storage and this
        // exact check is therefore a cheap identity walk. It is still
        // required for correctness: a late tool/status patch must never be
        // hidden merely because an assistant tail is streaming at the same
        // time. Any non-tail mutation falls back to the rebuild path below;
        // only Markdown template/unit construction remains tail-local.
        let candidateIDSet = Set(candidateIDs)
        for index in seeds.indices where !candidateIDSet.contains(seeds[index].id) {
            guard seeds[index] == cachedSeeds[index].seed else { return nil }
        }

        var changedIndices: [Int] = []
        changedIndices.reserveCapacity(candidateIndices.count)
        for index in candidateIndices {
            let seed = seeds[index]
            let nextStreaming = streamingSeedIDs.contains(seed.id)
            let cached = cachedSeeds[index]
            if nextStreaming != cached.streaming || seed.text != cached.seed.text {
                changedIndices.append(index)
            }
        }

        if changedIndices.isEmpty {
            lastWork = TranscriptRenderPlannerWork(
                mode: .cached,
                inspectedSeedCount: seeds.count,
                rebuiltSeedCount: 0,
                rebuiltUnitCount: 0,
                reusedUnitCount: cachedPlan.units.count,
                planUnitCount: cachedPlan.units.count
            )
            return cachedPlan
        }

        let branchSeedIndex = branchSourceID.flatMap { sourceID in
            seeds.firstIndex { $0.sourceIDs.contains(sourceID) }
        }
        var nextSeeds = cachedSeeds
        var nextPlanUnits = cachedPlan.units
        var replacedUnitCount = 0
        var rebuiltUnitCount = 0

        // Replacing from the end keeps earlier ranges valid while Swift's
        // Array performs at most one suffix move per changed tail.  In the
        // normal streaming case this is one final range and is O(tail).
        for index in changedIndices.sorted(by: >) {
            let seed = seeds[index]
            let streaming = streamingSeedIDs.contains(seed.id)
            let templates = TranscriptRenderPlan.templates(for: seed, streaming: streaming)
            let units = TranscriptRenderPlan.units(
                for: seed,
                seedIndex: index,
                branchSeedIndex: branchSeedIndex,
                templates: templates
            )
            let oldRange = cachedUnitRanges[index]
            replacedUnitCount += oldRange.count
            rebuiltUnitCount += units.count
            nextPlanUnits.replaceSubrange(oldRange, with: units)
            nextSeeds[index] = CachedSeed(
                seed: seed,
                streaming: streaming,
                templates: templates,
                units: units
            )
            seedCache[seed.id] = nextSeeds[index]
        }

        cachedSeeds = nextSeeds
        cachedStreamingSeedIDs = streamingSeedIDs
        cachedPlan = TranscriptRenderPlan(units: nextPlanUnits, branchSeedIndex: branchSeedIndex)
        rebuildUnitRanges()
        lastWork = TranscriptRenderPlannerWork(
            mode: .incremental,
            inspectedSeedCount: seeds.count,
            rebuiltSeedCount: changedIndices.count,
            rebuiltUnitCount: rebuiltUnitCount,
            reusedUnitCount: max(0, cachedPlan.units.count - rebuiltUnitCount),
            planUnitCount: cachedPlan.units.count
        )
        _ = statusChangedIDs // Kept named for diagnostics/readability above.
        return cachedPlan
    }

    private func structureMatches(_ seeds: [TranscriptRenderSeed]) -> Bool {
        guard seeds.count == cachedSeeds.count else { return false }
        for (index, seed) in seeds.enumerated() {
            let cached = cachedSeeds[index].seed
            guard seed.id == cached.id,
                  seed.kind == cached.kind,
                  seed.sourceIDs == cached.sourceIDs,
                  seed.hasMedia == cached.hasMedia else {
                return false
            }
        }
        return true
    }

    private func rebuild(
        seeds: [TranscriptRenderSeed],
        branchSourceID: String?,
        streamingSeedIDs: Set<String>,
        mode: TranscriptRenderPlannerWork.Mode
    ) -> TranscriptRenderPlan {
        let branchSeedIndex = branchSourceID.flatMap { sourceID in
            seeds.firstIndex { $0.sourceIDs.contains(sourceID) }
        }
        var nextSeeds: [CachedSeed] = []
        nextSeeds.reserveCapacity(seeds.count)
        var units: [TranscriptRenderUnit] = []
        units.reserveCapacity(max(seeds.count, cachedPlan.units.count))
        var rebuiltSeedCount = 0
        var rebuiltUnitCount = 0
        var liveIDs: Set<String> = []
        liveIDs.reserveCapacity(seeds.count)

        for (index, seed) in seeds.enumerated() {
            liveIDs.insert(seed.id)
            let streaming = streamingSeedIDs.contains(seed.id)
            let cached = seedCache[seed.id]
            let entry: CachedSeed
            if let cached,
               cached.seed == seed,
               cached.streaming == streaming {
                entry = cached
            } else {
                let templates = TranscriptRenderPlan.templates(for: seed, streaming: streaming)
                let nextUnits = TranscriptRenderPlan.units(
                    for: seed,
                    seedIndex: index,
                    branchSeedIndex: branchSeedIndex,
                    templates: templates
                )
                entry = CachedSeed(
                    seed: seed,
                    streaming: streaming,
                    templates: templates,
                    units: nextUnits
                )
                seedCache[seed.id] = entry
                rebuiltSeedCount += 1
                rebuiltUnitCount += nextUnits.count
            }
            // Branch metadata is tied to the current branch source index. A
            // branch rebuild therefore refreshes units even when templates
            // came from the per-seed cache.
            let branchUnits = TranscriptRenderPlan.units(
                for: seed,
                seedIndex: index,
                branchSeedIndex: branchSeedIndex,
                templates: entry.templates
            )
            nextSeeds.append(CachedSeed(
                seed: seed,
                streaming: streaming,
                templates: entry.templates,
                units: branchUnits
            ))
            units.append(contentsOf: branchUnits)
            if branchUnits != entry.units {
                rebuiltUnitCount += branchUnits.count
            }
        }

        if seedCache.count > max(256, liveIDs.count * 2) {
            seedCache = seedCache.filter { liveIDs.contains($0.key) }
        }

        let next = TranscriptRenderPlan(units: units, branchSeedIndex: branchSeedIndex)
        cachedSeeds = nextSeeds
        cachedBranchSourceID = branchSourceID
        cachedStreamingSeedIDs = streamingSeedIDs
        cachedPlan = next
        rebuildUnitRanges()
        lastWork = TranscriptRenderPlannerWork(
            mode: mode,
            inspectedSeedCount: seeds.count,
            rebuiltSeedCount: rebuiltSeedCount,
            rebuiltUnitCount: rebuiltUnitCount,
            reusedUnitCount: max(0, next.units.count - rebuiltUnitCount),
            planUnitCount: next.units.count
        )
        return next
    }

    private func rebuildUnitRanges() {
        cachedUnitRanges.removeAll(keepingCapacity: true)
        cachedUnitRanges.reserveCapacity(cachedSeeds.count)
        var offset = 0
        for seed in cachedSeeds {
            let end = offset + seed.units.count
            cachedUnitRanges.append(offset..<end)
            offset = end
        }
    }
}
