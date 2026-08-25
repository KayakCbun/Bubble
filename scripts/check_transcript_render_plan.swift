import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum TranscriptRenderPlanCheck {
    static func main() {
        let longAnswer = Array(repeating: "A paragraph that can be rendered independently.", count: 260)
            .joined(separator: "\n\n")
        let seeds = (0..<600).flatMap { turn -> [TranscriptRenderSeed] in
            [
                TranscriptRenderSeed(
                    id: "user-\(turn)",
                    kind: .user,
                    text: "Question \(turn)",
                    sourceIDs: ["entry-user-\(turn)"]
                ),
                TranscriptRenderSeed(
                    id: "assistant-\(turn)",
                    kind: .assistant,
                    text: longAnswer,
                    sourceIDs: ["entry-assistant-\(turn)"]
                ),
            ]
        }

        let coldStart = ContinuousClock.now
        let plan = TranscriptRenderPlan.build(
            seeds: seeds,
            branchSourceID: "entry-user-300",
            streamingSeedIDs: []
        )
        let cold = coldStart.duration(to: .now)
        let coldMilliseconds = Double(cold.components.seconds) * 1_000
            + Double(cold.components.attoseconds) / 1_000_000_000_000_000

        expect(plan.units.count > seeds.count * 3, "long assistant replies must split into virtual render units")
        expect(plan.units.contains(where: { $0.id == "assistant-599" }), "the first chunk keeps the source row id for stable scrolling")
        expect(plan.units.last?.id.hasPrefix("assistant-599-chunk-") == true, "continuation chunks get stable derived ids")

        let cutover = plan.units.firstIndex(where: { $0.startsAfterBranchPoint })
        expect(cutover != nil, "the plan precomputes one branch cutover")
        if let cutover {
            expect(plan.units[cutover].seedIndex > plan.units[cutover - 1].seedIndex, "branch divider starts on the next source row")
            expect(plan.units[cutover].isAfterBranchPoint, "branch metadata is computed once in the plan")
        }

        let streaming = TranscriptRenderPlan.build(
            seeds: Array(seeds.suffix(2)),
            branchSourceID: nil,
            streamingSeedIDs: ["assistant-599"]
        )
        expect(streaming.units.count > 2, "a long streaming answer splits into stable render units")
        expect(streaming.units.first(where: { $0.kind == .assistant })?.isChunked == true, "the source-id chunk still renders as a chunk")
        expect(streaming.units.last?.isTerminal == true, "the live tail is marked explicitly")
        expect(streaming.units.last?.isStreaming == true, "the live tail keeps streaming presentation state")
        expect(streaming.units.last?.copyText == nil, "copy and branch controls stay hidden while streaming")
        expect(
            TranscriptChunkRenderPolicy.sourceText(longAnswer, isChunked: true).isEmpty,
            "stable prefix chunk keys exclude the complete growing source text"
        )
        expect(
            !TranscriptChunkRenderPolicy.sourceIsLive(
                sourceIsLive: true,
                isChunked: true,
                isStreaming: true,
                isTerminal: false
            ),
            "only the terminal chunk invalidates for streaming presentation"
        )
        let streamingIDs = streaming.units.map(\.id)
        var grownSeeds = Array(seeds.suffix(2))
        grownSeeds[grownSeeds.count - 1].text += "\n\nA newly streamed tail paragraph."
        let grownStreaming = TranscriptRenderPlan.build(
            seeds: grownSeeds,
            branchSourceID: nil,
            streamingSeedIDs: ["assistant-599"]
        )
        expect(
            Array(grownStreaming.units.map(\.id).prefix(streamingIDs.count)) == streamingIDs,
            "stream growth preserves every existing chunk identity"
        )

        let unicode = Array(repeating: "中文段落 🫧 keeps its UTF-8 boundary intact.", count: 180)
            .joined(separator: "\n\n")
        let unicodeChunks = WorkspaceTranscriptChunker.chunks(unicode, identity: "unicode")
        expect(unicodeChunks.joined() == unicode, "UTF-8 chunking must be lossless")
        let longCode = "```swift\n" + Array(repeating: "let value = 1", count: 1_200).joined(separator: "\n") + "\n```"
        let codeChunks = WorkspaceTranscriptChunker.chunks(longCode, identity: "long-code")
        expect(codeChunks.count > 4, "a giant fenced code block virtualizes into independently valid fences")
        expect(
            codeChunks.allSatisfy { $0.hasPrefix("```swift\n") && $0.hasSuffix("```") },
            "every virtual code row preserves fenced-code semantics"
        )
        let giantTable = "| A | B |\n|---|---|\n" + Array(repeating: "| 1 | 2 |", count: 12_000).joined(separator: "\n")
        let tableChunks = WorkspaceTranscriptChunker.chunks(giantTable, identity: "giant-table")
        expect(tableChunks.count > 20, "a giant GFM table virtualizes into repeated-header row groups")
        expect(tableChunks.allSatisfy { $0.hasPrefix("| A | B |\n|---|---|\n") }, "every virtual table row preserves its header")
        let mixedTable = "Summary before the table.\n\n" + giantTable + "\n\nConclusion after the table."
        let mixedTableChunks = WorkspaceTranscriptChunker.chunks(mixedTable, identity: "mixed-table")
        expect(mixedTableChunks.count > tableChunks.count, "a large table embedded in prose still virtualizes")
        expect(mixedTableChunks.first == "Summary before the table.", "mixed-table prefix keeps its prose semantics")
        expect(mixedTableChunks.last == "Conclusion after the table.", "mixed-table suffix keeps its prose semantics")
        expect(
            mixedTableChunks.dropFirst().dropLast().allSatisfy { $0.hasPrefix("| A | B |\n|---|---|\n") },
            "every mixed-table virtual row repeats the table header"
        )
        let documentScoped = [
            Array(repeating: "sequenceDiagram\nA->>B: hello", count: 120).joined(separator: "\n"),
        ]
        for (index, document) in documentScoped.enumerated() {
            expect(
                WorkspaceTranscriptChunker.chunks(document, identity: "document-\(index)").count == 1,
                "document-scoped Markdown must never be split into semantically invalid rows"
            )
        }

        let planner = TranscriptRenderPlanner()
        _ = planner.plan(seeds: seeds, branchSourceID: nil, streamingSeedIDs: [])
        var streamingSeeds = seeds
        streamingSeeds[streamingSeeds.count - 1].text += "\n\nA newly streamed tail paragraph."
        let incrementalStart = ContinuousClock.now
        let incremental = planner.plan(
            seeds: streamingSeeds,
            branchSourceID: nil,
            streamingSeedIDs: ["assistant-599"]
        )
        let incrementalElapsed = incrementalStart.duration(to: .now)
        let incrementalMilliseconds = Double(incrementalElapsed.components.seconds) * 1_000
            + Double(incrementalElapsed.components.attoseconds) / 1_000_000_000_000_000
        expect(incremental.units.last?.text.hasSuffix("A newly streamed tail paragraph.") == true, "streaming updates only replace the live tail unit")
        expect(incrementalMilliseconds < 20, "a streaming tail update must stay near one frame, got \(incrementalMilliseconds)ms")

        let structuredSource = "```swift\n" + Array(repeating: "let stableStructuredRow = true", count: 5_000).joined(separator: "\n")
        let structuredPlanner = TranscriptRenderPlanner()
        let structuredSeed = TranscriptRenderSeed(id: "structured", kind: .assistant, text: structuredSource)
        let structuredBefore = structuredPlanner.plan(
            seeds: [structuredSeed],
            branchSourceID: nil,
            streamingSeedIDs: ["structured"]
        )
        var grownStructuredSeed = structuredSeed
        grownStructuredSeed.text += "\nlet liveStructuredTail = true"
        let structuredStart = ContinuousClock.now
        let structuredAfter = structuredPlanner.plan(
            seeds: [grownStructuredSeed],
            branchSourceID: nil,
            streamingSeedIDs: ["structured"]
        )
        let structuredElapsed = structuredStart.duration(to: .now)
        let structuredMilliseconds = Double(structuredElapsed.components.seconds) * 1_000
            + Double(structuredElapsed.components.attoseconds) / 1_000_000_000_000_000
        expect(structuredAfter.units.count > 20, "100k+ streaming code is split into bounded render rows")
        expect(
            Array(structuredAfter.units.map(\.id).prefix(structuredBefore.units.count))
                == structuredBefore.units.map(\.id),
            "structured stream growth preserves every existing row identity"
        )
        expect(structuredMilliseconds < 20, "100k+ structured stream planning must stay near one frame, got \(structuredMilliseconds)ms")
        let tablePlanner = TranscriptRenderPlanner()
        let tableSeed = TranscriptRenderSeed(id: "table", kind: .assistant, text: giantTable)
        let tableBefore = tablePlanner.plan(seeds: [tableSeed], branchSourceID: nil, streamingSeedIDs: ["table"])
        var grownTableSeed = tableSeed
        grownTableSeed.text += "\n| live | tail |"
        let tableStart = ContinuousClock.now
        let tableAfter = tablePlanner.plan(seeds: [grownTableSeed], branchSourceID: nil, streamingSeedIDs: ["table"])
        let tableElapsed = tableStart.duration(to: .now)
        let tableMilliseconds = Double(tableElapsed.components.seconds) * 1_000
            + Double(tableElapsed.components.attoseconds) / 1_000_000_000_000_000
        expect(tableAfter.units.count > 20, "100k+ streaming table remains split into bounded render rows")
        expect(
            Array(tableAfter.units.map(\.id).prefix(tableBefore.units.count)) == tableBefore.units.map(\.id),
            "table stream growth preserves every existing row identity"
        )
        expect(tableMilliseconds < 20, "100k+ table stream planning must stay near one frame, got \(tableMilliseconds)ms")
        let mixedTablePlanner = TranscriptRenderPlanner()
        let mixedTableSeed = TranscriptRenderSeed(id: "mixed-table", kind: .assistant, text: mixedTable)
        let mixedTableBefore = mixedTablePlanner.plan(
            seeds: [mixedTableSeed],
            branchSourceID: nil,
            streamingSeedIDs: ["mixed-table"]
        )
        var grownMixedTableSeed = mixedTableSeed
        grownMixedTableSeed.text = "Summary before the table.\n\n" + giantTable
            + "\n| live | tail |\n\nConclusion after the table."
        let mixedTableAfter = mixedTablePlanner.plan(
            seeds: [grownMixedTableSeed],
            branchSourceID: nil,
            streamingSeedIDs: ["mixed-table"]
        )
        expect(
            Array(mixedTableAfter.units.map(\.id).prefix(mixedTableBefore.units.count - 2))
                == Array(mixedTableBefore.units.map(\.id).prefix(mixedTableBefore.units.count - 2)),
            "mixed-table growth preserves completed prefix row identities"
        )
        _ = planner.plan(seeds: seeds, branchSourceID: nil, streamingSeedIDs: [])
        let warmStart = ContinuousClock.now
        var checksum = 0
        for _ in 0..<20 {
            checksum += planner.plan(
                seeds: seeds,
                branchSourceID: nil,
                streamingSeedIDs: []
            ).units.count
        }
        let warm = warmStart.duration(to: .now)
        let warmMilliseconds = Double(warm.components.seconds) * 1_000
            + Double(warm.components.attoseconds) / 1_000_000_000_000_000

        expect(checksum > 0, "benchmark must consume every plan")
        expect(coldMilliseconds < 350, "1,200 rich rows must plan in under 350ms cold, got \(coldMilliseconds)ms")
        expect(warmMilliseconds < 300, "cached repeated planning must stay under 300ms, got \(warmMilliseconds)ms")
        print(String(format: "PASS: transcript render plan cold=%.1fms incremental=%.1fms warm20=%.1fms units=%d", coldMilliseconds, incrementalMilliseconds, warmMilliseconds, plan.units.count))
    }
}
