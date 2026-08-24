import AppKit
import Foundation
import SwiftUI

enum OverlayMetrics {
    static let transcriptWidthDefault: CGFloat = 760
    static let transcriptInset: CGFloat = 24
    static let fontSize: CGFloat = 13
    static let heading1Size: CGFloat = 16
    static let heading2Size: CGFloat = 14
    static let heading3Size: CGFloat = 13
    static let chipSize: CGFloat = 12
    static var bodyFont: Font { .system(size: fontSize) }
    static var ink: Color { Color(nsColor: .textColor) }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct WorkspaceRenderPerfCheck {
    static let paragraph = """
    **主要结论。** Workspace session 需要展示当次调用的完整上下文，同时保证滚动不重复解析同一段富文本。路径 `/Users/bytedance/Documents/work/Bubble/Sources/Bubble/OverlayView.swift` 和 `open_id` 都应保持可读。
    """

    static func main() async {
        let response = Array(repeating: paragraph, count: 80).joined(separator: "\n\n")
        let iterations = 40
        let warmupStart = ContinuousClock.now
        await Task.detached(priority: .userInitiated) {
            WorkspaceTranscriptWarmup.prepare([
                WorkspaceTranscriptWarmupItem(
                    identity: "cold-workspace-response",
                    text: response
                ),
            ])
        }.value
        let warmupElapsed = warmupStart.duration(to: .now)
        let warmupMilliseconds = Double(warmupElapsed.components.seconds) * 1_000
            + Double(warmupElapsed.components.attoseconds) / 1_000_000_000_000_000
        print(String(format: "workspace background warmup: %.1f ms", warmupMilliseconds))

        let coldStart = ContinuousClock.now
        let coldChunks = WorkspaceTranscriptChunker.chunks(
            response,
            identity: "cold-workspace-response"
        )
        let coldPlanElapsed = coldStart.duration(to: .now)
        let coldBlocks = ProseParser.blocks(in: coldChunks[coldChunks.count - 1])
        let coldElapsed = coldStart.duration(to: .now)
        let coldPlanMilliseconds = Double(coldPlanElapsed.components.seconds) * 1_000
            + Double(coldPlanElapsed.components.attoseconds) / 1_000_000_000_000_000
        let coldMilliseconds = Double(coldElapsed.components.seconds) * 1_000
            + Double(coldElapsed.components.attoseconds) / 1_000_000_000_000_000
        print(String(format: "workspace cold plan: %.1f ms; + first chunk: %.1f ms", coldPlanMilliseconds, coldMilliseconds))
        expect(coldChunks.count > 8 && !coldBlocks.isEmpty, "opening prewarms the output-end render unit used by auto-positioning")
        expect(coldMilliseconds < 10, "revealing a prewarmed workspace must stay inside one 120 Hz frame budget, got \(coldMilliseconds)ms")

        let warm = ProseParser.blocks(in: response)
        expect(warm.count == 80, "warm parse covers the full assistant response")
        let start = ContinuousClock.now
        var checksum = 0
        for _ in 0..<iterations {
            let blocks = ProseParser.blocks(in: response)
            checksum += blocks.count
        }
        let elapsed = start.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        print(String(format: "workspace prose parse: %.1f ms, checksum=%d", milliseconds, checksum))
        expect(checksum == 80 * iterations, "benchmark must drive every workspace prose block")
        expect(milliseconds < 10, "revisiting long workspace rows must reuse parsed prose (<10ms), got \(milliseconds)ms")

        let chunks = WorkspaceTranscriptChunker.chunks(response)
        expect(chunks.count > 8, "long workspace output exposes multiple lazy render units")
        let chunkStart = ContinuousClock.now
        var chunkChecksum = 0
        for _ in 0..<iterations {
            chunkChecksum += WorkspaceTranscriptChunker.chunks(response).count
        }
        let chunkElapsed = chunkStart.duration(to: .now)
        let chunkMilliseconds = Double(chunkElapsed.components.seconds) * 1_000
            + Double(chunkElapsed.components.attoseconds) / 1_000_000_000_000_000
        print(String(format: "workspace chunk plan: %.1f ms, checksum=%d", chunkMilliseconds, chunkChecksum))
        expect(chunkMilliseconds < 10, "revisiting a workspace answer must reuse its lazy chunk plan (<10ms), got \(chunkMilliseconds)ms")
    }
}
