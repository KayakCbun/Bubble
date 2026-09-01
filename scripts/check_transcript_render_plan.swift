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

        for seed in seeds where seed.kind == .assistant {
            _ = WorkspaceTranscriptChunker.chunks(seed.text, identity: seed.id)
        }
        let preparedStart = ContinuousClock.now
        let preparedPlan = TranscriptRenderPlanner().plan(
            seeds: seeds,
            branchSourceID: nil,
            streamingSeedIDs: []
        )
        let preparedElapsed = preparedStart.duration(to: .now)
        let preparedMilliseconds = Double(preparedElapsed.components.seconds) * 1_000
            + Double(preparedElapsed.components.attoseconds) / 1_000_000_000_000_000
        expect(preparedPlan.units.count == plan.units.count, "prepared session presentation must preserve every render unit")
        expect(
            preparedMilliseconds < 40,
            "a background-prepared long session must build its presentation plan within 40ms, got \(preparedMilliseconds)ms"
        )

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

        // Mirrors the restored 2.3 KB usage/benchmark answer that previously
        // became four separately clipped NSHostingView rows. Ordinary
        // completed prose should stay one semantic row; chunking is reserved
        // for genuinely large completed output and active streaming tails.
        let ordinaryCompletedText = Array(
            repeating: String(repeating: "usage benchmark tool context ", count: 12),
            count: 8
        ).joined(separator: "\n\n")
        let ordinaryCompleted = TranscriptRenderPlan.build(
            seeds: [TranscriptRenderSeed(
                id: "ordinary-completed",
                kind: .assistant,
                text: ordinaryCompletedText
            )],
            branchSourceID: nil,
            streamingSeedIDs: []
        )
        expect(
            ordinaryCompleted.units.count == 1,
            "ordinary completed prose stays one host instead of creating visible chunk seams"
        )
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
        expect(
            codeChunks == [longCode],
            "one fenced code block must remain one transcript row; its code view owns internal virtualization"
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
        expect(planner.lastWork.mode == .incremental, "streaming tail uses the incremental planner path")
        expect(planner.lastWork.rebuiltSeedCount == 1, "streaming tail rebuilds one source seed")
        expect(planner.lastWork.rebuiltUnitCount < planner.lastWork.planUnitCount / 4, "streaming tail rebuilds only a small unit suffix")
        expect(planner.lastWork.reusedUnitCount > planner.lastWork.rebuiltUnitCount, "streaming tail reuses the immutable unit prefix")

        let directPlanner = TranscriptRenderPlanner()
        let retainedDirectPlan = directPlanner.plan(seeds: seeds, branchSourceID: nil, streamingSeedIDs: [])
        let detachedCopiesBeforeDirect = directPlanner.detachedPlanCopyCount
        var directSeeds = seeds
        directSeeds[directSeeds.count - 1].text += "\n\nDirect index-addressed tail."
        directSeeds[directSeeds.count - 1].contentVersion &+= 1
        directSeeds[directSeeds.count - 1].appendedText = "\n\nDirect index-addressed tail."
        let directStart = ContinuousClock.now
        let directDelta = directPlanner.applyStreamingUpdate(
            seedIndex: directSeeds.count - 1,
            seed: directSeeds[directSeeds.count - 1],
            streaming: true,
            branchSourceID: nil
        )
        let directElapsed = directStart.duration(to: .now)
        let directMilliseconds = Double(directElapsed.components.seconds) * 1_000
            + Double(directElapsed.components.attoseconds) / 1_000_000_000_000_000
        expect(directDelta != nil, "index-addressed streaming update is accepted for the live tail")
        expect(directPlanner.lastWork.inspectedSeedCount == 1, "index-addressed streaming update inspects one seed")
        expect(directPlanner.lastWork.changedSeedIndices == [directSeeds.count - 1], "index-addressed update reports one changed seed")
        expect(directPlanner.detachedPlanCopyCount == detachedCopiesBeforeDirect, "direct update does not copy a retained public plan")
        expect(directPlanner.lastWork.detachedUnitCopyCount == 0, "direct update reports zero full-plan copies")
        expect(retainedDirectPlan.units.last?.text != directSeeds.last?.text, "retained public plan remains immutable after direct update")
        expect(directMilliseconds < 20, "index-addressed streaming update stays near one frame, got \(directMilliseconds)ms")
        if let directDelta {
            expect(directDelta.changedUnits.count < directDelta.fullUnitCount / 4, "index-addressed update materializes only the changed unit suffix")
        }
        directSeeds[directSeeds.count - 1].text += " token"
        directSeeds[directSeeds.count - 1].contentVersion &+= 1
        directSeeds[directSeeds.count - 1].appendedText = " token"
        let steadyStreamingDelta = directPlanner.applyStreamingUpdate(
            seedIndex: directSeeds.count - 1,
            seed: directSeeds[directSeeds.count - 1],
            streaming: true,
            branchSourceID: nil
        )
        expect(
            steadyStreamingDelta?.changedUnits.count == 1,
            "steady streaming updates only the live render unit, not completed chunks"
        )
        directSeeds[directSeeds.count - 1].contentVersion &+= 1
        directSeeds[directSeeds.count - 1].appendedText = nil
        let metadataOnlyDelta = directPlanner.applyStreamingUpdate(
            seedIndex: directSeeds.count - 1,
            seed: directSeeds[directSeeds.count - 1],
            streaming: true,
            branchSourceID: nil
        )
        expect(
            metadataOnlyDelta?.changedUnits.count == 1,
            "metadata-only tool/image mutations still refresh their mounted row"
        )
        expect(
            !WorkspaceTranscriptChunker.canIncrementallyAppend("\n```swift\n"),
            "a newly opened fenced block leaves the paragraph-tail fast path"
        )

        let thoughtPlanner = TranscriptRenderPlanner()
        var thoughtSeeds = [
            TranscriptRenderSeed(id: "user-thought", kind: .user, text: "Question"),
            TranscriptRenderSeed(id: "thought-tail", kind: .other, text: "Thinking")
        ]
        _ = thoughtPlanner.plan(seeds: thoughtSeeds, branchSourceID: nil, streamingSeedIDs: [])
        thoughtSeeds[1].text += " one more step"
        thoughtSeeds[1].contentVersion &+= 1
        thoughtSeeds[1].appendedText = " one more step"
        let thoughtDelta = thoughtPlanner.applyStreamingUpdate(
            seedIndex: 1,
            seed: thoughtSeeds[1],
            streaming: false,
            branchSourceID: nil
        )
        expect(
            thoughtDelta?.changedUnits.count == 1,
            "thought/COT text uses the same single-row delta path"
        )
        let workspaceStatusPlanner = TranscriptRenderPlanner()
        var workspaceStatusSeeds = [
            TranscriptRenderSeed(id: "workspace-user", kind: .user, text: "Question"),
            TranscriptRenderSeed(
                id: "workspace-card",
                kind: .other,
                text: "",
                contentVersion: 1,
                isChunkable: false
            ),
            TranscriptRenderSeed(id: "workspace-answer", kind: .assistant, text: "Final answer")
        ]
        _ = workspaceStatusPlanner.plan(
            seeds: workspaceStatusSeeds,
            branchSourceID: nil,
            streamingSeedIDs: []
        )
        workspaceStatusSeeds[1].contentVersion &+= 1
        let workspaceStatusDelta = workspaceStatusPlanner.applyStreamingUpdate(
            seedIndex: 1,
            seed: workspaceStatusSeeds[1],
            streaming: false,
            branchSourceID: nil
        )
        expect(
            workspaceStatusDelta?.changedSeedIndex == 1
                && workspaceStatusDelta?.changedUnits.count == 1,
            "a completed middle workspace card refreshes its mounted metadata-only row"
        )
        let coalescedPlanner = TranscriptRenderPlanner()
        var coalescedSeeds = [
            TranscriptRenderSeed(id: "coalesced-user", kind: .user, text: "Question"),
            TranscriptRenderSeed(id: "coalesced-thought", kind: .other, text: "Thought"),
            TranscriptRenderSeed(id: "coalesced-answer", kind: .assistant, text: "Answer")
        ]
        _ = coalescedPlanner.plan(
            seeds: coalescedSeeds,
            branchSourceID: nil,
            streamingSeedIDs: ["coalesced-thought", "coalesced-answer"]
        )
        coalescedSeeds[1].text += " step"
        coalescedSeeds[2].text += " token"
        coalescedSeeds[1].contentVersion &+= 1
        coalescedSeeds[1].appendedText = " step"
        coalescedSeeds[2].contentVersion &+= 1
        coalescedSeeds[2].appendedText = " token"
        let coalescedThought = coalescedPlanner.applyStreamingUpdate(
            seedIndex: 1,
            seed: coalescedSeeds[1],
            streaming: true,
            branchSourceID: nil
        )
        let coalescedAnswer = coalescedPlanner.applyStreamingUpdate(
            seedIndex: 2,
            seed: coalescedSeeds[2],
            streaming: true,
            branchSourceID: nil
        )
        expect(
            coalescedThought?.changedUnits.count == 1
                && coalescedAnswer?.changedUnits.count == 1,
            "same-frame thought and answer updates stay row-local"
        )

        let unchangedStreaming = planner.plan(
            seeds: streamingSeeds,
            branchSourceID: nil,
            streamingSeedIDs: ["assistant-599"]
        )
        expect(unchangedStreaming == incremental, "unchanged stream input returns the cached plan")
        expect(planner.lastWork.mode == .cached, "unchanged stream input takes the cached path")

        var concurrentlyPatched = streamingSeeds
        concurrentlyPatched[0].text = "A late completed-prefix correction"
        let corrected = planner.plan(
            seeds: concurrentlyPatched,
            branchSourceID: nil,
            streamingSeedIDs: ["assistant-599"]
        )
        expect(
            corrected.units.first?.text == "A late completed-prefix correction",
            "an active stream never hides a simultaneous completed-prefix correction"
        )
        expect(
            planner.lastWork.mode == .rebuilt,
            "a completed-prefix correction safely leaves the tail-only fast path"
        )

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
        expect(structuredAfter.units.count == 1, "100k+ streaming code remains one transcript row")
        expect(
            structuredAfter.units.first?.id == structuredBefore.units.first?.id,
            "structured stream growth preserves the transcript row identity"
        )
        expect(structuredMilliseconds < 20, "100k+ structured stream planning must stay near one frame, got \(structuredMilliseconds)ms")
        var directStructuredSeed = structuredSeed
        let directStructuredPlanner = TranscriptRenderPlanner()
        _ = directStructuredPlanner.plan(
            seeds: [directStructuredSeed],
            branchSourceID: nil,
            streamingSeedIDs: ["structured"]
        )
        var directStructuredDurations: [Double] = []
        for version in 1...20 {
            let token = "\nlet directToken\(version) = true"
            directStructuredSeed.text += token
            directStructuredSeed.contentVersion = UInt64(version)
            directStructuredSeed.appendedText = token
            let started = ContinuousClock.now
            let delta = directStructuredPlanner.applyStreamingUpdate(
                seedIndex: 0,
                seed: directStructuredSeed,
                streaming: true,
                branchSourceID: nil
            )
            let elapsed = started.duration(to: .now)
            directStructuredDurations.append(
                Double(elapsed.components.seconds) * 1_000
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
            )
            expect(delta?.changedUnits.count == 1, "structured direct stream updates one semantic unit")
        }
        expect(
            directStructuredDurations.sorted()[18] < 17,
            "100k+ structured direct updates stay inside one frame"
        )
        expect(
            !WorkspaceTranscriptChunker.canIncrementallyAppend("\n| A | B |\n"),
            "GFM table append leaves the paragraph-local fast path"
        )
        expect(
            !WorkspaceTranscriptChunker.canIncrementallyAppend("\ngraph TD"),
            "diagram append leaves the paragraph-local fast path"
        )
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
        let longProsePlanner = TranscriptRenderPlanner()
        var longProseSeed = TranscriptRenderSeed(
            id: "long-prose",
            kind: .assistant,
            text: Array(repeating: String(repeating: "paragraph text ", count: 35), count: 400)
                .joined(separator: "\n\n")
        )
        _ = longProsePlanner.plan(
            seeds: [longProseSeed],
            branchSourceID: nil,
            streamingSeedIDs: ["long-prose"]
        )
        var longProseDurations: [Double] = []
        for version in 0..<20 {
            let token = " token-\(version)"
            longProseSeed.text += token
            longProseSeed.contentVersion &+= 1
            longProseSeed.appendedText = token
            let started = ContinuousClock.now
            let delta = longProsePlanner.applyStreamingUpdate(
                seedIndex: 0,
                seed: longProseSeed,
                streaming: true,
                branchSourceID: nil
            )
            let elapsed = started.duration(to: .now)
            longProseDurations.append(
                Double(elapsed.components.seconds) * 1_000
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
            )
            expect(delta?.changedUnits.count == 1, "long prose token updates only its live tail unit")
        }
        let longProseP95 = longProseDurations.sorted()[18]
        expect(longProseP95 < 17, "long prose token planning p95 stays inside one frame, got \(longProseP95)ms")
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
        // Hosted macOS runners have noisier cold process and allocator startup
        // than a warmed developer machine. Keep the local gate strict while
        // allowing a bounded CI margin that still catches large regressions.
        let coldLimitMilliseconds = ProcessInfo.processInfo.environment["CI"] == "true" ? 550.0 : 350.0
        expect(
            coldMilliseconds < coldLimitMilliseconds,
            "1,200 rich rows must plan in under \(Int(coldLimitMilliseconds))ms cold, got \(coldMilliseconds)ms"
        )
        expect(warmMilliseconds < 300, "cached repeated planning must stay under 300ms, got \(warmMilliseconds)ms")
        print(String(
            format: "PASS: transcript render plan cold=%.1fms prepared=%.1fms incremental=%.1fms warm20=%.1fms units=%d",
            coldMilliseconds,
            preparedMilliseconds,
            incrementalMilliseconds,
            warmMilliseconds,
            plan.units.count
        ))
    }
}
