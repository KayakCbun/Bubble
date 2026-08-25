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
        expect(plan.units.last?.id == "assistant-599", "the terminal chunk keeps the source row id for stable scrolling")
        expect(plan.units.dropLast().contains(where: { $0.id.hasPrefix("assistant-599-chunk-") }), "non-terminal chunks get stable derived ids")

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
        expect(streaming.units.count == 2, "a streaming answer stays one stable tail unit")
        expect(streaming.units.last?.text == longAnswer, "the live unit carries the complete current text")

        let unicode = Array(repeating: "中文段落 🫧 keeps its UTF-8 boundary intact.", count: 180)
            .joined(separator: "\n\n")
        let unicodeChunks = WorkspaceTranscriptChunker.chunks(unicode, identity: "unicode")
        expect(unicodeChunks.joined() == unicode, "UTF-8 chunking must be lossless")
        let documentScoped = [
            Array(repeating: "```swift\nlet value = 1\n```", count: 120).joined(separator: "\n\n"),
            Array(repeating: "| A | B |\n|---|---|\n| 1 | 2 |", count: 120).joined(separator: "\n"),
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
