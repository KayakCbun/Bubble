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

        let planner = TranscriptRenderPlanner()
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
        expect(coldMilliseconds < 250, "1,200 rich rows must plan in under 250ms cold, got \(coldMilliseconds)ms")
        expect(warmMilliseconds < 300, "cached repeated planning must stay under 300ms, got \(warmMilliseconds)ms")
        print(String(format: "PASS: transcript render plan cold=%.1fms warm20=%.1fms units=%d", coldMilliseconds, warmMilliseconds, plan.units.count))
    }
}
