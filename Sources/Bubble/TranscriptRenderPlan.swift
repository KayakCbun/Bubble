import Foundation

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

    init(id: String, kind: Kind, text: String, sourceIDs: Set<String> = []) {
        self.id = id
        self.kind = kind
        self.text = text
        self.sourceIDs = sourceIDs
    }
}

struct TranscriptRenderUnit: Identifiable, Equatable, Sendable {
    var id: String
    var seedIndex: Int
    var kind: TranscriptRenderSeed.Kind
    var text: String
    var copyText: String?
    var isContinuation: Bool
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
            let isAfterBranchPoint = branchSeedIndex.map { seedIndex > $0 } ?? false
            let startsAfterBranchPoint = branchSeedIndex.map { seedIndex == $0 + 1 } ?? false
            for template in templates[seedIndex] {
                units.append(TranscriptRenderUnit(
                    id: template.id,
                    seedIndex: seedIndex,
                    kind: seed.kind,
                    text: template.text,
                    copyText: template.copyText,
                    isContinuation: template.isContinuation,
                    isAfterBranchPoint: isAfterBranchPoint,
                    startsAfterBranchPoint: startsAfterBranchPoint && !template.isContinuation
                ))
            }
        }

        return TranscriptRenderPlan(units: units, branchSeedIndex: branchSeedIndex)
    }

    fileprivate static func templates(
        for seed: TranscriptRenderSeed,
        streaming: Bool
    ) -> [TranscriptRenderTemplate] {
        let chunks = seed.kind == .assistant && !streaming
            ? WorkspaceTranscriptChunker.chunks(seed.text, identity: seed.id)
            : [seed.text]
        return chunks.enumerated().map { chunkIndex, text in
            let isLast = chunkIndex == chunks.count - 1
            return TranscriptRenderTemplate(
                id: isLast ? seed.id : "\(seed.id)-chunk-\(chunkIndex)",
                text: text,
                copyText: chunks.count > 1 && isLast ? seed.text : nil,
                isContinuation: chunkIndex > 0
            )
        }
    }
}

private struct TranscriptRenderTemplate {
    var id: String
    var text: String
    var copyText: String?
    var isContinuation: Bool
}

/// Keeps the row and chunk plan stable across unrelated SwiftUI updates. The
/// per-seed cache means a streaming tail rebuilds only its own render unit;
/// completed history reuses the same chunk strings and identities.
final class TranscriptRenderPlanner {
    private struct CachedSeed {
        var seed: TranscriptRenderSeed
        var streaming: Bool
        var templates: [TranscriptRenderTemplate]
    }

    private var cachedSeeds: [TranscriptRenderSeed] = []
    private var cachedBranchSourceID: String?
    private var cachedStreamingSeedIDs: Set<String> = []
    private var cachedPlan = TranscriptRenderPlan(units: [], branchSeedIndex: nil)
    private var seedCache: [String: CachedSeed] = [:]

    func plan(
        seeds: [TranscriptRenderSeed],
        branchSourceID: String?,
        streamingSeedIDs: Set<String>
    ) -> TranscriptRenderPlan {
        if seeds == cachedSeeds,
           branchSourceID == cachedBranchSourceID,
           streamingSeedIDs == cachedStreamingSeedIDs {
            return cachedPlan
        }

        var templates: [[TranscriptRenderTemplate]] = []
        templates.reserveCapacity(seeds.count)
        var liveIDs: Set<String> = []
        liveIDs.reserveCapacity(seeds.count)
        for seed in seeds {
            liveIDs.insert(seed.id)
            let streaming = streamingSeedIDs.contains(seed.id)
            if let cached = seedCache[seed.id],
               cached.seed == seed,
               cached.streaming == streaming {
                templates.append(cached.templates)
            } else {
                let next = TranscriptRenderPlan.templates(for: seed, streaming: streaming)
                seedCache[seed.id] = CachedSeed(seed: seed, streaming: streaming, templates: next)
                templates.append(next)
            }
        }
        if seedCache.count > max(256, liveIDs.count * 2) {
            seedCache = seedCache.filter { liveIDs.contains($0.key) }
        }

        let next = TranscriptRenderPlan.build(
            seeds: seeds,
            branchSourceID: branchSourceID,
            templates: templates
        )
        cachedSeeds = seeds
        cachedBranchSourceID = branchSourceID
        cachedStreamingSeedIDs = streamingSeedIDs
        cachedPlan = next
        return next
    }
}
