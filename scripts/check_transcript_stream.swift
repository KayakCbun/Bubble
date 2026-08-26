import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct TranscriptStreamCheck {
    static func main() {
        testThoughtChunksMerge()
        testThoughtDoesNotSplitAssistant()
        testToolStartsNewAssistant()
        testCJKSentenceStaysOneParagraph()
        testCoalesceSavedTranscript()
        testWorkspaceCardReuse()
        testWorkspaceCardDedupe()
        print("PASS: transcript stream merge")
    }

    static func testThoughtChunksMerge() {
        var kinds: [String] = []
        var texts: [String] = []
        func absorbThought(_ piece: String) {
            if TranscriptStream.shouldMergeThought(previousKind: kinds.last) {
                texts[texts.count - 1] += piece
            } else {
                kinds.append("thought")
                texts.append(piece)
            }
        }
        for ch in ["先", "核", "对", "对", "接"] {
            absorbThought(ch)
        }
        expect(kinds == ["thought"], "one-character thought chunks become one row \(kinds)")
        expect(texts == ["先核对对接"], "thought text concatenates \(texts)")
        kinds.append("tool")
        texts.append("read")
        absorbThought("下一步")
        expect(kinds == ["thought", "tool", "thought"], "a tool starts a new thought row \(kinds)")
        expect(texts.last == "下一步", "new thought after tool \(texts)")
    }

    static func testThoughtDoesNotSplitAssistant() {
        let kinds = ["user", "thought", "assistant", "thought"]
        expect(
            TranscriptStream.resumeAssistantIndex(kinds: kinds) == 2,
            "late thought still resumes the same assistant bubble"
        )
        let withCard = ["user", "thought", "assistant", "workspaceRun"]
        expect(
            TranscriptStream.resumeAssistantIndex(kinds: withCard) == 2,
            "workspace card after speech still resumes the assistant"
        )
        let splitRepro = ["user", "thought", "assistant", "thought"]
        expect(
            TranscriptStream.resumeAssistantIndex(kinds: splitRepro) == 2,
            "这是多 / 维表格 split: thought between chunks must not open a new assistant"
        )
    }

    static func testToolStartsNewAssistant() {
        let kinds = ["user", "assistant", "tool"]
        expect(
            TranscriptStream.resumeAssistantIndex(kinds: kinds) == nil,
            "a visible tool starts a new assistant bubble"
        )
        let system = ["user", "assistant", "system"]
        expect(
            TranscriptStream.resumeAssistantIndex(kinds: system) == nil,
            "system messages start a new assistant bubble"
        )
    }

    static func testCJKSentenceStaysOneParagraph() {
        let sentence = "这是多维表格同步字段类型被改写的问题，我找到 qiaogeya-agent 里查。"
        let reflowed = ProseReflow.reflow(sentence)
        expect(reflowed == sentence, "CJK sentence is not reflowed into extra lines \(reflowed.debugDescription)")
        expect(!reflowed.contains("\n"), "CJK sentence has no inserted newline")
        let kinds = ["user", "thought", "assistant"]
        expect(
            TranscriptStream.resumeAssistantIndex(kinds: kinds) == 2,
            "first answer tokens resume into one bubble: 这是多 + 维表格"
        )
    }

    static func testCoalesceSavedTranscript() {
        let glued = TranscriptStream.joinText("这是多", "维表格同步字段类型被改写的问题")
        expect(glued == "这是多维表格同步字段类型被改写的问题", "saved CJK split glues without a space \(glued)")
        let items = TranscriptStream.coalesce([
            .init(kind: "user", text: "查一下"),
            .init(kind: "thought", text: "The user wants"),
            .init(kind: "assistant", text: "这是多"),
            .init(kind: "assistant", text: "维表格同步字段类型被改写的问题，我放到 qiaogeya-agent 里查。"),
            .init(kind: "workspaceRun", text: "qiaogeya-agent", children: [
                .init(kind: "thought", text: "先"),
                .init(kind: "thought", text: "核"),
                .init(kind: "thought", text: "对"),
                .init(kind: "tool", text: "read"),
                .init(kind: "thought", text: "下一步"),
                .init(kind: "thought", text: ""),
            ]),
        ])
        expect(items.count == 4, "adjacent assistant bubbles collapse \(items.map(\.kind))")
        expect(items[2].kind == "assistant", "assistant stays assistant")
        expect(
            items[2].text == "这是多维表格同步字段类型被改写的问题，我放到 qiaogeya-agent 里查。",
            "old 这是多 / 维表格 record becomes one sentence \(items[2].text)"
        )
        expect(items[3].children.map(\.kind) == ["thought", "tool", "thought"], "child thoughts merge around tools \(items[3].children.map(\.kind))")
        expect(items[3].children[0].text == "先核对", "CJK child thoughts glue \(items[3].children[0].text)")
        let acrossTool = TranscriptStream.coalesce([
            .init(kind: "assistant", text: "先看文件"),
            .init(kind: "tool", text: "read"),
            .init(kind: "assistant", text: "结论如下"),
        ])
        expect(acrossTool.count == 3, "do not glue assistant text across a tool")
        let twoReplies = TranscriptStream.coalesce([
            .init(kind: "assistant", text: "先看 Pi 怎么加模型，以及你这边现有的配置。"),
            .init(kind: "assistant", text: "已经加到 models.json 里了。"),
        ])
        expect(twoReplies.count == 2, "two complete replies stay two bubbles \(twoReplies.count)")
        let old = "收到。文字是「测试文本」，图是 Bubble 空会话截图。"
        let replayed = TranscriptStream.truncatedAssistant(
            "去掉了。models.json 里现在只剩 gcli/grok-4.5。" + old,
            earlier: [old]
        )
        expect(
            replayed == "去掉了。models.json 里现在只剩 gcli/grok-4.5。",
            "replayed history is stripped from the last bubble \(replayed)"
        )
        let once = "通了。有活直接说。先看现有配置再动手。"
        let doubled = TranscriptStream.collapseSelfRepeat(once + once)
        expect(doubled == once, "exact doubled reply collapses \(doubled)")
    }

    static func testWorkspaceCardReuse() {
        expect(
            TranscriptStream.shouldReuseWorkspaceCard(existingStatus: "running", userSpokeAfter: false),
            "an in-flight card keeps receiving updates"
        )
        expect(
            TranscriptStream.shouldReuseWorkspaceCard(existingStatus: "waiting", userSpokeAfter: false),
            "a waiting card is still the live run"
        )
        expect(
            !TranscriptStream.shouldReuseWorkspaceCard(existingStatus: "running", userSpokeAfter: true),
            "a later user turn opens a new card even if the old one is still running"
        )
        expect(
            TranscriptStream.shouldReuseWorkspaceCard(
                existingStatus: "done",
                userSpokeAfter: true,
                sameRun: true
            ),
            "repeated updates for the same run reuse the existing card even after a parent user turn"
        )
        expect(
            !TranscriptStream.shouldReuseWorkspaceCard(existingStatus: "failed", userSpokeAfter: false),
            "a failed run does not reuse the old card"
        )
        expect(
            !TranscriptStream.shouldReuseWorkspaceCard(existingStatus: "interrupted", userSpokeAfter: false),
            "an interrupted run does not reuse the old card"
        )
    }

    static func testWorkspaceCardDedupe() {
        let original = TranscriptStream.WorkspaceRunRecord(
            path: "/repo",
            runId: "run-a",
            sessionId: "session",
            goal: "goal",
            status: "done",
            summary: "result",
            anchorEntryId: "entry-a"
        )
        let duplicate = TranscriptStream.WorkspaceRunRecord(
            path: "/repo",
            runId: "run-a",
            sessionId: "session",
            goal: "goal",
            status: "done",
            summary: "result truncated",
            anchorEntryId: nil
        )
        let separateRun = TranscriptStream.WorkspaceRunRecord(
            path: "/repo",
            runId: "run-b",
            sessionId: "session",
            goal: "goal",
            status: "done",
            summary: "result",
            anchorEntryId: "entry-b"
        )
        let result = TranscriptStream.deduplicateWorkspaceRuns([original, duplicate, duplicate, separateRun])
        expect(result == [original, separateRun], "same-session missing-anchor replays collapse even when a summary is truncated")

        let unscopedA = TranscriptStream.WorkspaceRunRecord(
            path: "/repo",
            runId: nil,
            sessionId: nil,
            goal: "goal",
            status: "done",
            summary: "first result",
            anchorEntryId: nil
        )
        let unscopedB = TranscriptStream.WorkspaceRunRecord(
            path: "/repo",
            runId: nil,
            sessionId: nil,
            goal: "goal",
            status: "done",
            summary: "second result",
            anchorEntryId: nil
        )
        expect(
            TranscriptStream.deduplicateWorkspaceRuns([unscopedA, unscopedB]) == [unscopedA, unscopedB],
            "legacy cards without a session keep distinct summaries"
        )

        let legacyFull = TranscriptStream.WorkspaceRunRecord(
            path: "/repo",
            runId: nil,
            sessionId: "reused-session",
            goal: "legacy goal",
            status: "done",
            summary: "complete result with details",
            anchorEntryId: nil
        )
        let legacyTruncated = TranscriptStream.WorkspaceRunRecord(
            path: "/repo",
            runId: nil,
            sessionId: "reused-session",
            goal: "legacy goal",
            status: "done",
            summary: "complete result…",
            anchorEntryId: nil
        )
        let legacyDistinct = TranscriptStream.WorkspaceRunRecord(
            path: "/repo",
            runId: nil,
            sessionId: "reused-session",
            goal: "legacy goal",
            status: "done",
            summary: "a genuinely separate result",
            anchorEntryId: nil
        )
        expect(
            TranscriptStream.deduplicateWorkspaceRuns([legacyFull, legacyTruncated, legacyDistinct]) == [legacyFull, legacyDistinct],
            "legacy truncated replays collapse without treating a reused session as run identity"
        )
    }
}
