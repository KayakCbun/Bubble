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
        case thought
        case other
    }

    var id: String
    var kind: Kind
    var text: String
    var sourceIDs: Set<String>
    var hasMedia: Bool
    /// Producer-owned O(1) mutation token. Direct streaming updates compare
    /// this instead of rescanning an ever-growing String for equality.
    var contentVersion: UInt64
    /// Exact newly appended stream fragment when the producer can prove the
    /// mutation was append-only. It lets the chunker revisit only the live
    /// tail instead of reparsing completed paragraphs.
    var appendedText: String?
    var isChunkable: Bool

    init(
        id: String,
        kind: Kind,
        text: String,
        sourceIDs: Set<String> = [],
        hasMedia: Bool = false,
        contentVersion: UInt64 = 0,
        appendedText: String? = nil,
        isChunkable: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.sourceIDs = sourceIDs
        self.hasMedia = hasMedia
        self.contentVersion = contentVersion
        self.appendedText = appendedText
        self.isChunkable = isChunkable ?? (kind == .assistant && !hasMedia)
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
        let chunks = seed.isChunkable && !seed.hasMedia
            ? WorkspaceTranscriptChunker.chunks(seed.text, identity: seed.id)
            : [seed.text]
        return templates(seed: seed, chunks: chunks, streaming: streaming)
    }

    fileprivate static func templates(
        seed: TranscriptRenderSeed,
        appending appendedText: String,
        to existing: [TranscriptRenderTemplate],
        streaming: Bool
    ) -> [TranscriptRenderTemplate] {
        guard seed.isChunkable, !seed.hasMedia, !existing.isEmpty else {
            return templates(for: seed, streaming: streaming)
        }
        let chunks = WorkspaceTranscriptChunker.appending(
            appendedText,
            to: existing.map(\.text)
        )
        return templates(seed: seed, chunks: chunks, streaming: streaming)
    }

    fileprivate static func templates(
        seed: TranscriptRenderSeed,
        chunks: [String],
        streaming: Bool,
        startingAt startIndex: Int = 0
    ) -> [TranscriptRenderTemplate] {
        return chunks.enumerated().map { chunkIndex, text in
            let globalIndex = startIndex + chunkIndex
            let isLast = chunkIndex == chunks.count - 1
            return TranscriptRenderTemplate(
                id: globalIndex == 0 ? seed.id : "\(seed.id)-chunk-\(globalIndex)",
                text: text,
                copyText: (startIndex + chunks.count) > 1 && isLast && !streaming ? seed.text : nil,
                isContinuation: globalIndex > 0,
                isChunked: (startIndex + chunks.count) > 1,
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
    /// Number of full unit values copied for a public cold-path plan
    /// snapshot. Direct streaming deltas must leave this at zero.
    var detachedUnitCopyCount = 0
    /// Seed indexes whose templates/units were rebuilt for this request.  A
    /// streaming token normally contains exactly one tail index; structural
    /// rebuilds report the complete set for correctness diagnostics.
    var changedSeedIndices: [Int] = []
}

struct TranscriptRenderPlannerUpdate: Sendable {
    let plan: TranscriptRenderPlan
    let work: TranscriptRenderPlannerWork
    /// Flattened unit ranges corresponding to `work.changedSeedIndices`.
    /// Consumers can patch only these units without scanning the whole plan.
    let changedUnitRanges: [Range<Int>]

    var isIncremental: Bool { work.mode == .incremental }
}

/// Result of an index-addressed streaming mutation.  Unlike `planUpdate`,
/// this API never accepts or returns the full seed/unit arrays.  It is valid
/// only while the source sequence and branch metadata are unchanged; callers
/// fall back to `planUpdate` when those preconditions do not hold.
struct TranscriptRenderPlannerDelta: Sendable {
    let work: TranscriptRenderPlannerWork
    let changedSeedIndex: Int
    let previousUnitRange: Range<Int>
    let changedUnits: [TranscriptRenderUnit]
    let fullUnitCount: Int

    var newUnitRange: Range<Int> {
        previousUnitRange.lowerBound..<(previousUnitRange.lowerBound + changedUnits.count)
    }
}

/// Keeps the row and chunk plan stable across unrelated SwiftUI updates. The
/// per-seed cache means a streaming tail rebuilds only its own render unit;
/// completed history reuses the same chunk strings and identities.
final class TranscriptRenderPlanner {
    private final class CachedSeed {
        var seed: TranscriptRenderSeed
        var streaming: Bool
        var templates: [TranscriptRenderTemplate]
        var units: [TranscriptRenderUnit]

        init(
            seed: TranscriptRenderSeed,
            streaming: Bool,
            templates: [TranscriptRenderTemplate],
            units: [TranscriptRenderUnit]
        ) {
            self.seed = seed
            self.streaming = streaming
            self.templates = templates
            self.units = units
        }
    }

    private var cachedSeeds: [CachedSeed] = []
    private var cachedBranchSourceID: String?
    private var cachedStreamingSeedIDs: Set<String> = []
    private var cachedPlan = TranscriptRenderPlan(units: [], branchSeedIndex: nil)
    private var seedCache: [String: CachedSeed] = [:]
    private var cachedUnitRanges: [Range<Int>] = []

    private(set) var lastWork = TranscriptRenderPlannerWork()
    /// Diagnostic counter for the cold/public plan boundary. It is kept
    /// separate from `lastWork` so a retained plan can be compared with a
    /// subsequent direct update in focused checks.
    private(set) var detachedPlanCopyCount = 0

    /// Plan a request and expose the exact flattened ranges touched by the
    /// planner.  The legacy `plan` API remains unchanged for structural
    /// consumers; Overlay uses this delta form on token updates.
    func planUpdate(
        seeds: [TranscriptRenderSeed],
        branchSourceID: String?,
        streamingSeedIDs: Set<String>
    ) -> TranscriptRenderPlannerUpdate {
        let plan = plan(
            seeds: seeds,
            branchSourceID: branchSourceID,
            streamingSeedIDs: streamingSeedIDs
        )
        let ranges: [Range<Int>] = lastWork.changedSeedIndices.compactMap { index in
            guard cachedUnitRanges.indices.contains(index) else { return nil }
            return cachedUnitRanges[index]
        }
        return TranscriptRenderPlannerUpdate(plan: plan, work: lastWork, changedUnitRanges: ranges)
    }

    /// Applies a known streaming-tail seed update without walking the prefix
    /// or creating an Array snapshot.  The caller supplies the existing seed
    /// index from its source projection, so no id search/structure comparison
    /// is needed here. A middle-sequence edit is accepted only when its unit
    /// count remains stable; count-changing edits rebuild because they shift
    /// every later flattened range.
    func applyStreamingUpdate(
        seedIndex: Int,
        seed: TranscriptRenderSeed,
        streaming: Bool,
        branchSourceID: String?
    ) -> TranscriptRenderPlannerDelta? {
        guard !cachedSeeds.isEmpty,
              cachedSeeds.indices.contains(seedIndex),
              cachedBranchSourceID == branchSourceID else {
            return nil
        }
        let cached = cachedSeeds[seedIndex]
        guard cached.seed.id == seed.id,
              cached.seed.kind == seed.kind,
              cached.seed.sourceIDs == seed.sourceIDs,
              cached.seed.hasMedia == seed.hasMedia,
              cached.seed.isChunkable == seed.isChunkable else {
            return nil
        }
        guard cached.streaming != streaming
                || cached.seed.contentVersion != seed.contentVersion else {
            lastWork = TranscriptRenderPlannerWork(
                mode: .cached,
                inspectedSeedCount: 1,
                reusedUnitCount: cachedPlan.units.count,
                planUnitCount: cachedPlan.units.count,
                changedSeedIndices: []
            )
            return nil
        }

        if cached.streaming,
           streaming,
           let appendedText = seed.appendedText,
           !appendedText.isEmpty,
           WorkspaceTranscriptChunker.canIncrementallyAppend(appendedText),
           let delta = applyAppendOnlyUpdate(
                cached: cached,
                seedIndex: seedIndex,
                seed: seed,
                appendedText: appendedText
           ) {
            return delta
        }

        let templates: [TranscriptRenderTemplate]
        if cached.streaming,
           streaming,
           let appendedText = seed.appendedText,
           !appendedText.isEmpty,
           WorkspaceTranscriptChunker.canIncrementallyAppend(appendedText) {
            templates = TranscriptRenderPlan.templates(
                seed: seed,
                appending: appendedText,
                to: cached.templates,
                streaming: streaming
            )
        } else {
            templates = TranscriptRenderPlan.templates(for: seed, streaming: streaming)
        }
        let units = TranscriptRenderPlan.units(
            for: seed,
            seedIndex: seedIndex,
            branchSeedIndex: cachedPlan.branchSeedIndex,
            templates: templates
        )
        // A middle seed may update in place only when it keeps the same unit
        // count; otherwise every later flattened range would shift. The live
        // tail may grow or shrink because no subsequent range depends on it.
        guard seedIndex == cachedSeeds.count - 1 || units.count == cached.units.count else {
            return nil
        }
        let oldRange = cachedUnitRanges[seedIndex]
        // Paragraph chunks before the live edge are immutable. Return only
        // the first changed suffix to Overlay so an incoming token does not
        // reconfigure every already-rendered chunk of a long answer. The
        // comparison is confined to the active seed; completed history is
        // never visited.
        var stableUnitPrefixCount = 0
        let comparableCount = min(cached.units.count, units.count)
        while stableUnitPrefixCount < comparableCount,
              cached.units[stableUnitPrefixCount] == units[stableUnitPrefixCount] {
            stableUnitPrefixCount += 1
        }
        if stableUnitPrefixCount == comparableCount,
           seed.contentVersion != cached.seed.contentVersion,
           stableUnitPrefixCount > 0 {
            // Source-only mutations (tool status/output, assistant images,
            // branch/media metadata) still have to refresh the mounted row
            // even when their flattened text unit is byte-identical.
            stableUnitPrefixCount -= 1
        }
        let changedOldRange = (oldRange.lowerBound + stableUnitPrefixCount)..<oldRange.upperBound
        let changedUnits = Array(units.dropFirst(stableUnitPrefixCount))
        // Mutate the planner's sole-owned arrays in place. No previous plan
        // is handed to this API, so replacing this final range cannot trigger
        // a full-prefix COW allocation.
        cachedSeeds[seedIndex] = CachedSeed(
            seed: seed,
            streaming: streaming,
            templates: templates,
            units: units
        )
        seedCache[seed.id] = cachedSeeds[seedIndex]
        cachedPlan.units.replaceSubrange(oldRange, with: units)
        cachedStreamingSeedIDs = streaming
            ? cachedStreamingSeedIDs.union([seed.id])
            : cachedStreamingSeedIDs.subtracting([seed.id])
        cachedUnitRanges[seedIndex] = oldRange.lowerBound..<(oldRange.lowerBound + units.count)
        let work = TranscriptRenderPlannerWork(
            mode: .incremental,
            inspectedSeedCount: 1,
            rebuiltSeedCount: 1,
            rebuiltUnitCount: changedUnits.count,
            reusedUnitCount: max(0, cachedPlan.units.count - changedUnits.count),
            planUnitCount: cachedPlan.units.count,
            changedSeedIndices: [seedIndex]
        )
        lastWork = work
        return TranscriptRenderPlannerDelta(
            work: work,
            changedSeedIndex: seedIndex,
            previousUnitRange: changedOldRange,
            changedUnits: changedUnits,
            fullUnitCount: cachedPlan.units.count
        )
    }

    private func applyAppendOnlyUpdate(
        cached: CachedSeed,
        seedIndex: Int,
        seed: TranscriptRenderSeed,
        appendedText: String
    ) -> TranscriptRenderPlannerDelta? {
        guard seed.isChunkable,
              !seed.hasMedia,
              let liveTemplate = cached.templates.last else { return nil }
        let replacementChunks: [String]
        if cached.templates.count == 1, !appendedText.contains("\n\n") {
            // Fenced Markdown and long single paragraphs intentionally stay a
            // single semantic unit. Updating that unit does not require
            // rescanning the complete document in the planner.
            replacementChunks = [seed.text]
        } else {
            replacementChunks = WorkspaceTranscriptChunker.replacementTailChunks(
                liveTail: liveTemplate.text,
                appendedText: appendedText
            )
        }
        let replacementStart = max(0, cached.templates.count - 1)
        let replacementTemplates = TranscriptRenderPlan.templates(
            seed: seed,
            chunks: replacementChunks,
            streaming: true,
            startingAt: replacementStart
        )
        let replacementUnits = TranscriptRenderPlan.units(
            for: seed,
            seedIndex: seedIndex,
            branchSeedIndex: cachedPlan.branchSeedIndex,
            templates: replacementTemplates
        )
        let oldSeedRange = cachedUnitRanges[seedIndex]
        let changedOldRange = (oldSeedRange.upperBound - 1)..<oldSeedRange.upperBound
        let newSeedUnitCount = cached.units.count - 1 + replacementUnits.count
        guard seedIndex == cachedSeeds.count - 1 || newSeedUnitCount == cached.units.count else {
            return nil
        }

        cached.seed = seed
        cached.streaming = true
        cached.templates.replaceSubrange(replacementStart..<cached.templates.count, with: replacementTemplates)
        cached.units.replaceSubrange((cached.units.count - 1)..<cached.units.count, with: replacementUnits)
        cachedPlan.units.replaceSubrange(changedOldRange, with: replacementUnits)
        cachedUnitRanges[seedIndex] = oldSeedRange.lowerBound..<(oldSeedRange.lowerBound + newSeedUnitCount)
        seedCache[seed.id] = cached
        let work = TranscriptRenderPlannerWork(
            mode: .incremental,
            inspectedSeedCount: 1,
            rebuiltSeedCount: 1,
            rebuiltUnitCount: replacementUnits.count,
            reusedUnitCount: max(0, cachedPlan.units.count - replacementUnits.count),
            planUnitCount: cachedPlan.units.count,
            changedSeedIndices: [seedIndex]
        )
        lastWork = work
        return TranscriptRenderPlannerDelta(
            work: work,
            changedSeedIndex: seedIndex,
            previousUnitRange: changedOldRange,
            changedUnits: replacementUnits,
            fullUnitCount: cachedPlan.units.count
        )
    }

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
                planUnitCount: cachedPlan.units.count,
                changedSeedIndices: []
            )
            return detachedPlan()
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
            if nextStreaming != cached.streaming
                || seed.contentVersion != cached.seed.contentVersion
                || seed.text != cached.seed.text {
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
                planUnitCount: cachedPlan.units.count,
                changedSeedIndices: []
            )
            return detachedPlan()
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
            planUnitCount: cachedPlan.units.count,
            changedSeedIndices: changedIndices.sorted()
        )
        _ = statusChangedIDs // Kept named for diagnostics/readability above.
        return detachedPlan()
    }

    private func structureMatches(_ seeds: [TranscriptRenderSeed]) -> Bool {
        guard seeds.count == cachedSeeds.count else { return false }
        for (index, seed) in seeds.enumerated() {
            let cached = cachedSeeds[index].seed
            guard seed.id == cached.id,
                  seed.kind == cached.kind,
                  seed.sourceIDs == cached.sourceIDs,
                  seed.hasMedia == cached.hasMedia,
                  seed.isChunkable == cached.isChunkable else {
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
            planUnitCount: next.units.count,
            changedSeedIndices: seeds.indices.map { $0 }
        )
        // Keep the planner's internal unit buffer uniquely owned. The public
        // plan is a cold-path value snapshot; callers retaining it must not
        // force copy-on-write of the live tail on the next direct update.
        detachedPlanCopyCount += next.units.count
        lastWork.detachedUnitCopyCount = next.units.count
        return TranscriptRenderPlan(
            units: next.units.map { $0 },
            branchSeedIndex: next.branchSeedIndex
        )
    }

    /// Returns a detached value for structural/cached consumers. Keeping the
    /// internal `cachedPlan.units` array private and uniquely owned is what
    /// lets `applyStreamingUpdate` replace one tail range without copying a
    /// caller-retained full plan.
    private func detachedPlan() -> TranscriptRenderPlan {
        detachedPlanCopyCount += cachedPlan.units.count
        lastWork.detachedUnitCopyCount = cachedPlan.units.count
        return TranscriptRenderPlan(
            units: cachedPlan.units.map { $0 },
            branchSeedIndex: cachedPlan.branchSeedIndex
        )
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
