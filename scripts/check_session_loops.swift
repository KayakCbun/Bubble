import Foundation

@main
struct SessionLoopCheck {
    static func main() {
        testParse()
        testRaisedInterval()
        testCreateLimits()
        testDueCoalesce()
        testFireOrder()
        testClosePausesWithoutDeleting()
        testResumeMarksElapsedDue()
        testModelText()
        testPersistence()
        print("session loop checks passed")
    }

    private static func testParse() {
        expectSuccess(SessionLoopPolicy.parseCommand(""), .help, "empty /loop is help")
        expectSuccess(SessionLoopPolicy.parseCommand("list"), .list, "list command")
        expectSuccess(SessionLoopPolicy.parseCommand("stop"), .stop(id: nil), "stop without id")
        expectSuccess(
            SessionLoopPolicy.parseCommand("stop ab12cd34"),
            .stop(id: "ab12cd34"),
            "stop with id"
        )

        switch SessionLoopPolicy.parseCommand("5m 检查部署") {
        case .success(.create(let schedule, let prompt)):
            expect(schedule == .interval(seconds: 300), "5m is five minutes")
            expect(prompt == "检查部署", "prompt follows the interval")
        default:
            fail("5m should create an interval loop")
        }

        switch SessionLoopPolicy.parseCommand("1h look at logs") {
        case .success(.create(let schedule, let prompt)):
            expect(schedule == .interval(seconds: 3600), "1h is one hour")
            expect(prompt == "look at logs", "english prompt is kept")
        default:
            fail("1h should create an interval loop")
        }

        switch SessionLoopPolicy.parseCommand("9:00 写日报") {
        case .success(.create(let schedule, let prompt)):
            expect(schedule == .daily(hour: 9, minute: 0), "9:00 is daily")
            expect(prompt == "写日报", "daily prompt is kept")
        default:
            fail("9:00 should create a daily loop")
        }

        switch SessionLoopPolicy.parseCommand("每天 09:30 看发布") {
        case .success(.create(let schedule, let prompt)):
            expect(schedule == .daily(hour: 9, minute: 30), "每天 09:30 is daily")
            expect(prompt == "看发布", "每天 prompt is kept")
        default:
            fail("每天 09:30 should create a daily loop")
        }

        expectFailure(SessionLoopPolicy.parseCommand("5m"), .emptyPrompt, "schedule without prompt")
        expectFailure(SessionLoopPolicy.parseCommand("soon 检查"), .invalidSchedule, "unknown schedule")
        expect(
            SessionLoopPolicy.intervalLabel(.interval(seconds: 300)) == "每 5 分钟",
            "interval label is Chinese"
        )
        expect(
            SessionLoopPolicy.intervalLabel(.daily(hour: 9, minute: 0)) == "每天 09:00",
            "daily label is Chinese"
        )
    }

    private static func testRaisedInterval() {
        expect(SessionLoopPolicy.raisedIntervalSeconds(30) == 60, "sub-minute raises to 1 minute")
        expect(SessionLoopPolicy.raisedIntervalSeconds(90) == 90, "90s stays 90s")
        switch SessionLoopPolicy.parseCommand("30s 看一下") {
        case .success(.create(let schedule, _)):
            expect(schedule == .interval(seconds: 60), "30s command raises to 1 minute")
        default:
            fail("30s should parse as a raised interval")
        }
    }

    private static func testCreateLimits() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        do {
            _ = try SessionLoopPolicy.makeLoop(
                prompt: "  ",
                schedule: .interval(seconds: 60),
                now: now,
                calendar: utcCalendar,
                existingCount: 0
            )
            fail("blank prompt must be rejected")
        } catch {
            expect(error as? SessionLoopError == .emptyPrompt, "blank prompt is emptyPrompt")
        }
        do {
            _ = try SessionLoopPolicy.makeLoop(
                prompt: "check",
                schedule: .interval(seconds: 60),
                now: now,
                calendar: utcCalendar,
                existingCount: SessionLoopPolicy.maximumPerSession
            )
            fail("ninth loop must be rejected")
        } catch {
            expect(error as? SessionLoopError == .sessionLimit, "session cap is eight")
        }
        let loop = try! SessionLoopPolicy.makeLoop(
            prompt: "检查部署",
            schedule: .interval(seconds: 12),
            now: now,
            calendar: utcCalendar,
            existingCount: 0
        )
        expect(loop.schedule == .interval(seconds: 60), "create raises sub-minute intervals")
        expect(loop.nextFireAt == now.addingTimeInterval(60), "first fire is one interval later")
        expect(!loop.due, "a new loop is not immediately due")
    }

    private static func testDueCoalesce() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var loop = SessionLoop(
            id: "a",
            prompt: "check",
            title: "check",
            schedule: .interval(seconds: 60),
            nextFireAt: now,
            due: false,
            createdAt: now
        )
        loop = SessionLoopPolicy.noteTick(loop, now: now.addingTimeInterval(10))
        loop = SessionLoopPolicy.noteTick(loop, now: now.addingTimeInterval(70))
        loop = SessionLoopPolicy.noteTick(loop, now: now.addingTimeInterval(130))
        expect(loop.due, "elapsed ticks mark the loop due")
        expect(loop.nextFireAt == now, "busy ticks do not advance nextFireAt")

        let fired = SessionLoopPolicy.noteFired(loop, now: now.addingTimeInterval(130), calendar: utcCalendar)
        expect(!fired.due, "firing clears due")
        expect(
            fired.nextFireAt == now.addingTimeInterval(190),
            "the next fire is one interval after the actual shot, not a catch-up stack"
        )
    }

    private static func testFireOrder() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let dueA = SessionLoop(
            id: "a",
            prompt: "A",
            title: "A",
            schedule: .interval(seconds: 60),
            nextFireAt: now,
            due: true,
            createdAt: now
        )
        let dueB = SessionLoop(
            id: "b",
            prompt: "B",
            title: "B",
            schedule: .interval(seconds: 60),
            nextFireAt: now,
            due: true,
            createdAt: now.addingTimeInterval(1)
        )
        expect(
            SessionLoopPolicy.fireDecision(
                loops: [dueA, dueB],
                isBusy: true,
                hasQueuedUserFollowUp: false,
                isBranching: false
            ) == .waitForTurn,
            "busy assistant defers every due loop"
        )
        expect(
            SessionLoopPolicy.fireDecision(
                loops: [dueA, dueB],
                isBusy: false,
                hasQueuedUserFollowUp: true,
                isBranching: false
            ) == .waitForUserFollowUp,
            "queued user follow-up is not overtaken by a loop"
        )
        expect(
            SessionLoopPolicy.fireDecision(
                loops: [dueA, dueB],
                isBusy: false,
                hasQueuedUserFollowUp: false,
                isBranching: false
            ) == .fire(dueA),
            "idle fire takes one due loop"
        )
        expect(
            SessionLoopPolicy.fireDecision(
                loops: [dueA, dueB],
                isBusy: false,
                hasQueuedUserFollowUp: false,
                isBranching: true
            ) == .waitForTurn,
            "branching does not fire"
        )
        expect(
            SessionLoopPolicy.pendingStatus(isBusy: true, hasQueuedUserFollowUp: false)
                == "待执行，等当前回复结束",
            "list copy matches the product string"
        )
    }

    private static func testClosePausesWithoutDeleting() {
        expect(!SessionLoopPolicy.shouldConfirmClose(loopCount: 0), "no confirm without loops")
        expect(SessionLoopPolicy.shouldConfirmClose(loopCount: 1), "confirm when the window still has loops")
        let prompt = SessionLoopClosePrompt(intent: .closeSideSession, count: 2)
        expect(
            prompt.message.contains("这些定时会停"),
            "close copy says loops pause"
        )
        expect(
            prompt.message.contains("下次打开这个对话再继续"),
            "close copy is not a permanent delete"
        )
        expect(!prompt.message.contains("删除"), "close copy must not say delete")
    }

    private static func testResumeMarksElapsedDue() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let paused = SessionLoop(
            id: "a",
            prompt: "check",
            title: "check",
            schedule: .interval(seconds: 300),
            nextFireAt: now.addingTimeInterval(-10),
            due: false,
            createdAt: now.addingTimeInterval(-400)
        )
        let armed = SessionLoopPolicy.rearm([paused], now: now)
        expect(armed[0].due, "elapsed loops come back due on resume")
        expect(armed[0].id == paused.id, "resume keeps the same loop identity")
        expect(armed[0].prompt == paused.prompt, "resume keeps the prompt")
    }

    private static func testModelText() {
        expect(
            SessionLoopPolicy.modelText("检查部署") == "到点了，执行「检查部署」。接着当前上下文做，不要寒暄。",
            "the model still receives a user-shaped task"
        )
        expect(
            SessionLoopPolicy.shortID("abcdef12-3456-7890-abcd-ef1234567890") == "abcdef12",
            "slash stop can use a short id"
        )
        switch SessionLoopPolicy.resolveID("abcdef12", in: [
            SessionLoop(
                id: "abcdef12-3456-7890-abcd-ef1234567890",
                prompt: "x",
                title: "x",
                schedule: .interval(seconds: 60),
                nextFireAt: Date(),
                createdAt: Date()
            )
        ]) {
        case .success(let loop):
            expect(loop.prompt == "x", "short id resolves")
        default:
            fail("short id should resolve a unique loop")
        }
    }

    private static func testPersistence() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bubble-loop-check-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var file = SessionLoopStoreFile()
        let loop = SessionLoop(
            id: "keep-me",
            prompt: "检查部署",
            title: "检查部署",
            schedule: .interval(seconds: 300),
            nextFireAt: now.addingTimeInterval(300),
            due: true,
            createdAt: now
        )
        file.setLoops([loop], for: "session-a")
        try! file.save(to: url)
        let loaded = SessionLoopStoreFile.load(from: url)
        expect(loaded.loops(for: "session-a").count == 1, "paused loops stay on disk")
        expect(loaded.loops(for: "session-a")[0].id == "keep-me", "loop identity survives close")
        expect(loaded.loops(for: "session-a")[0].due, "due state survives close")
        expect(loaded.loops(for: "session-b").isEmpty, "other sessions stay empty")
        file.setLoops([], for: "session-a")
        try! file.save(to: url)
        expect(SessionLoopStoreFile.load(from: url).sessions["session-a"] == nil, "empty sessions drop from disk")
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func expectSuccess(
        _ result: Result<SessionLoopCommand, SessionLoopError>,
        _ expected: SessionLoopCommand,
        _ message: String
    ) {
        switch result {
        case .success(let command):
            expect(command == expected, message)
        case .failure(let error):
            fail("\(message): \(error)")
        }
    }

    private static func expectFailure(
        _ result: Result<SessionLoopCommand, SessionLoopError>,
        _ expected: SessionLoopError,
        _ message: String
    ) {
        switch result {
        case .failure(let error):
            expect(error == expected, message)
        case .success:
            fail("\(message): expected \(expected)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fail(message); return }
    }

    private static func fail(_ message: String) -> Never {
        fputs("session loop check failed: \(message)\n", stderr)
        exit(1)
    }
}
