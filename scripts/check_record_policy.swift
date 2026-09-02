import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct RecordPolicyCheck {
    static func main() {
        testParse()
        testToggle()
        testHideAndClose()
        testFlush()
        testLivePreview()
        testElapsedClock()
        testLiveElapsedTicksInOverlay()
        print("record policy checks passed")
    }

    private static func testParse() {
        expect(RecordPolicy.parseCommand("") == .toggle, "empty /record toggles")
        expect(RecordPolicy.parseCommand("  ") == .toggle, "whitespace /record toggles")
        expect(RecordPolicy.parseCommand("start") == .start, "start command")
        expect(RecordPolicy.parseCommand("STOP") == .stop, "stop command")
        expect(RecordPolicy.parseCommand("help") == .help, "help command")
        expect(RecordPolicy.parseCommand("unknown") == .help, "unknown args are help")
    }

    private static func testToggle() {
        expect(
            RecordPolicy.toggleAction(isRecording: false, ownerIsCurrentSession: true) == .start,
            "idle toggle starts"
        )
        expect(
            RecordPolicy.toggleAction(isRecording: true, ownerIsCurrentSession: true) == .stop,
            "second /record on the owner stops"
        )
        expect(
            RecordPolicy.toggleAction(isRecording: true, ownerIsCurrentSession: false)
                == .rejectAlreadyRecording,
            "another session cannot start a second Record"
        )
        expect(
            RecordPolicy.startAction(isRecording: false, ownerIsCurrentSession: true).isSuccess,
            "start from idle succeeds"
        )
        expect(
            RecordPolicy.stopAction(isRecording: false, ownerIsCurrentSession: true).error
                == .notRecording,
            "stop without a Record fails"
        )
        expect(
            RecordPolicy.stopAction(isRecording: true, ownerIsCurrentSession: false).error
                == .notRecording,
            "a non-owner cannot stop the Record"
        )
    }

    private static func testHideAndClose() {
        expect(RecordPolicy.hideKeepsRunning(), "hide keeps Record running")
        expect(
            RecordPolicy.shouldConfirmClose(isRecording: true, hasNotes: true),
            "close confirms when notes exist"
        )
        expect(
            !RecordPolicy.shouldConfirmClose(isRecording: true, hasNotes: false),
            "empty Record close does not confirm"
        )
        expect(
            !RecordPolicy.shouldConfirmClose(isRecording: false, hasNotes: true),
            "idle close does not confirm"
        )
        expect(
            RecordPolicy.shouldFlushOnClose(isRecording: true),
            "close of the owner stops and flushes"
        )
        expect(
            RecordPolicy.shouldQueueFlush(isBusy: true),
            "a busy turn queues the notes append"
        )
        expect(
            !RecordPolicy.shouldQueueFlush(isBusy: false),
            "an idle turn flushes notes immediately"
        )
    }

    private static func testFlush() {
        expect(
            RecordPolicy.flushPlan(notes: "   \n", duration: 12, recordID: "abc") == nil,
            "empty notes are discarded"
        )
        let short = RecordPolicy.flushPlan(
            notes: "hello meeting",
            duration: 12,
            recordID: "abc"
        )
        expect(short?.relativeFilePath == nil, "short notes stay inline")
        expect(short?.displayText.contains("录音笔记（12 秒）") == true, "short notes keep a duration heading")
        expect(short?.displayText.contains("hello meeting") == true, "short notes keep the body")

        let longBody = String(repeating: "会议内容很长。", count: 6_000)
        let long = RecordPolicy.flushPlan(
            notes: longBody,
            duration: 3600,
            recordID: "rec-1"
        )
        expect(long?.relativeFilePath == "records/rec-1.md", "long notes go to a workspace file")
        expect(long?.displayText.contains("@records/rec-1.md") == true, "long notes point at the file")
        expect(
            (long?.displayText.count ?? 0) < longBody.count,
            "the displayed message does not paste the whole file"
        )
        expect(RecordPolicy.durationLabel(12) == "12 秒", "sub-minute label")
        expect(RecordPolicy.durationLabel(180) == "3 分钟", "minute label")
    }

    private static func testLivePreview() {
        let notes = "one\ntwo\nthree\nfour\nfive"
        expect(
            RecordPolicy.liveCaptionPreview(notes) == "two\nthree\nfour\nfive",
            "live card keeps the last four lines"
        )
        expect(RecordPolicy.liveCaptionLineLimit == 4, "live caption cap is four lines")
    }

    private static func testElapsedClock() {
        expect(RecordPolicy.elapsedClockLabel(seconds: 0) == "0:00", "zero seconds is 0:00")
        expect(RecordPolicy.elapsedClockLabel(seconds: 5) == "0:05", "five seconds pads minutes")
        expect(RecordPolicy.elapsedClockLabel(seconds: 75) == "1:15", "seventy-five seconds is 1:15")
        expect(RecordPolicy.elapsedClockLabel(seconds: -3) == "0:00", "negative elapsed clamps to zero")
        let started = Date(timeIntervalSince1970: 1_000)
        expect(
            RecordPolicy.elapsedClockLabel(since: started, now: Date(timeIntervalSince1970: 1_065))
                == "1:05",
            "elapsed clock uses now minus startedAt"
        )
        expect(RecordPolicy.liveElapsedTickSeconds == 1, "live Record elapsed ticks once a second")
        expect(
            !RecordPolicy.shouldSendMicrophone(peak: 0),
            "silent microphone packets are not fed to the transcriber"
        )
        expect(
            RecordPolicy.shouldSendMicrophone(peak: 0.04),
            "audible microphone packets are transcribed"
        )
        expect(
            !RecordPolicy.shouldSendMicrophone(peak: 3.4e38),
            "garbage microphone peaks are not transcribed"
        )
        expect(
            RecordPolicy.noNotesMessage(durationSeconds: 12) == "录音了 12 秒，没有识别到能写进对话的语音。",
            "empty Record still writes a stop message"
        )
    }

    private static func testLiveElapsedTicksInOverlay() {
        let overlay = try! String(contentsOfFile: "Sources/Bubble/OverlayView.swift", encoding: .utf8)
        guard let start = overlay.range(of: "private func recordCard"),
              let end = overlay.range(
                of: "private func loopTriggerStrip",
                range: start.upperBound..<overlay.endIndex
              ) else {
            expect(false, "recordCard is in OverlayView")
            return
        }
        let body = overlay[start.lowerBound..<end.lowerBound]
        expect(
            body.contains("TimelineView(.periodic"),
            "live Record elapsed uses a periodic TimelineView so 0:00 does not freeze"
        )
        expect(
            body.contains("RecordPolicy.liveElapsedTickSeconds"),
            "live Record elapsed tick interval comes from RecordPolicy"
        )
        expect(
            body.contains("RecordPolicy.elapsedClockLabel"),
            "live Record elapsed text comes from RecordPolicy"
        )
        expect(
            !body.contains("Date().timeIntervalSince"),
            "live Record elapsed does not sample Date() only at first render"
        )
    }
}

private extension Result where Failure == RecordError {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var error: RecordError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
