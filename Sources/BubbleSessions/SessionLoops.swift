import Foundation

public enum SessionLoopSchedule: Equatable, Sendable {
    case interval(seconds: Int)
    case daily(hour: Int, minute: Int)
}

extension SessionLoopSchedule: Codable {
    enum Kind: String, Codable {
        case interval
        case daily
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case seconds
        case hour
        case minute
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .interval:
            self = .interval(seconds: try container.decode(Int.self, forKey: .seconds))
        case .daily:
            self = .daily(
                hour: try container.decode(Int.self, forKey: .hour),
                minute: try container.decode(Int.self, forKey: .minute)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .interval(let seconds):
            try container.encode(Kind.interval, forKey: .kind)
            try container.encode(seconds, forKey: .seconds)
        case .daily(let hour, let minute):
            try container.encode(Kind.daily, forKey: .kind)
            try container.encode(hour, forKey: .hour)
            try container.encode(minute, forKey: .minute)
        }
    }
}

public struct SessionLoop: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var prompt: String
    public var title: String
    public var schedule: SessionLoopSchedule
    public var nextFireAt: Date
    public var due: Bool
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        prompt: String,
        title: String,
        schedule: SessionLoopSchedule,
        nextFireAt: Date,
        due: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.prompt = prompt
        self.title = title
        self.schedule = schedule
        self.nextFireAt = nextFireAt
        self.due = due
        self.createdAt = createdAt
    }
}

public struct SessionLoopStoreFile: Codable, Equatable, Sendable {
    public var sessions: [String: [SessionLoop]]

    public init(sessions: [String: [SessionLoop]] = [:]) {
        self.sessions = sessions
    }

    public static func load(from url: URL) -> SessionLoopStoreFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let file = try? decoder.decode(SessionLoopStoreFile.self, from: data) else {
            return SessionLoopStoreFile()
        }
        return file
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    public func loops(for sessionID: String) -> [SessionLoop] {
        sessions[sessionID] ?? []
    }

    public mutating func setLoops(_ loops: [SessionLoop], for sessionID: String) {
        if loops.isEmpty {
            sessions.removeValue(forKey: sessionID)
        } else {
            sessions[sessionID] = loops
        }
    }
}

public enum SessionLoopCommand: Equatable, Sendable {
    case help
    case list
    case stop(id: String?)
    case create(schedule: SessionLoopSchedule, prompt: String)
}

public enum SessionLoopError: Error, Equatable, Sendable {
    case emptyPrompt
    case invalidSchedule
    case sessionLimit
    case notFound
    case noSession
    case ambiguousID
}

extension SessionLoopError: LocalizedError {
    public var errorDescription: String? {
        SessionLoopPolicy.errorMessage(self)
    }
}

public enum SessionLoopFireDecision: Equatable, Sendable {
    case fire(SessionLoop)
    case waitForTurn
    case waitForUserFollowUp
    case idleNone
}

public enum SessionLoopCloseIntent: Equatable, Sendable {
    case closeSideSession
    case startFresh
}

public struct SessionLoopClosePrompt: Equatable, Sendable {
    public var intent: SessionLoopCloseIntent
    public var count: Int

    public init(intent: SessionLoopCloseIntent, count: Int) {
        self.intent = intent
        self.count = count
    }

    public var title: String {
        switch intent {
        case .closeSideSession:
            return "关掉这个对话？"
        case .startFresh:
            return "开始新对话？"
        }
    }

    public var message: String {
        let noun = count == 1 ? "1 条定时" : "\(count) 条定时"
        switch intent {
        case .closeSideSession:
            return "这个对话还有\(noun)。关掉后这些定时会停，下次打开这个对话再继续。"
        case .startFresh:
            return "这个对话还有\(noun)。开始新对话后这些定时会停，下次打开这个对话再继续。"
        }
    }

    public var confirmTitle: String {
        switch intent {
        case .closeSideSession:
            return "关掉"
        case .startFresh:
            return "开始新对话"
        }
    }
}

public enum SessionLoopPolicy {
    public static let minimumIntervalSeconds = 60
    public static let maximumPerSession = 8

    public static func parseCommand(_ raw: String) -> Result<SessionLoopCommand, SessionLoopError> {
        let args = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if args.isEmpty { return .success(.help) }
        let lowered = args.lowercased()
        if lowered == "list" || lowered == "ls" {
            return .success(.list)
        }
        if lowered == "stop" || lowered == "delete" {
            return .success(.stop(id: nil))
        }
        if lowered.hasPrefix("stop ") || lowered.hasPrefix("delete ") {
            let id = String(args.split(separator: " ", maxSplits: 1)[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(.stop(id: id.isEmpty ? nil : id))
        }
        guard let parsed = consumeSchedule(args) else {
            return .failure(.invalidSchedule)
        }
        let prompt = parsed.rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return .failure(.emptyPrompt) }
        return .success(.create(schedule: parsed.schedule, prompt: prompt))
    }

    public static func parseScheduleToken(_ raw: String) -> SessionLoopSchedule? {
        consumeSchedule(raw)?.schedule
    }

    public static func raisedIntervalSeconds(_ seconds: Int) -> Int {
        max(seconds, minimumIntervalSeconds)
    }

    public static func makeLoop(
        prompt: String,
        schedule: SessionLoopSchedule,
        now: Date,
        calendar: Calendar,
        existingCount: Int,
        id: String = UUID().uuidString,
        title: String? = nil
    ) throws -> SessionLoop {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SessionLoopError.emptyPrompt }
        guard existingCount < maximumPerSession else { throw SessionLoopError.sessionLimit }
        let normalized = normalize(schedule)
        return SessionLoop(
            id: id,
            prompt: trimmed,
            title: title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
                ?? Self.title(from: trimmed),
            schedule: normalized,
            nextFireAt: nextFireDate(schedule: normalized, from: now, calendar: calendar),
            due: false,
            createdAt: now
        )
    }

    public static func rearm(_ loops: [SessionLoop], now: Date) -> [SessionLoop] {
        loops.map { loop in
            var next = loop
            if now >= loop.nextFireAt {
                next.due = true
            }
            return next
        }
    }

    public static func noteTick(_ loop: SessionLoop, now: Date) -> SessionLoop {
        var next = loop
        if now >= loop.nextFireAt {
            next.due = true
        }
        return next
    }

    public static func noteFired(
        _ loop: SessionLoop,
        now: Date,
        calendar: Calendar
    ) -> SessionLoop {
        var next = loop
        next.due = false
        next.nextFireAt = nextFireDate(schedule: loop.schedule, from: now, calendar: calendar)
        return next
    }

    public static func fireDecision(
        loops: [SessionLoop],
        isBusy: Bool,
        hasQueuedUserFollowUp: Bool,
        isBranching: Bool
    ) -> SessionLoopFireDecision {
        guard let due = loops.first(where: \.due) else { return .idleNone }
        if isBusy || isBranching { return .waitForTurn }
        if hasQueuedUserFollowUp { return .waitForUserFollowUp }
        return .fire(due)
    }

    public static func shouldConfirmClose(loopCount: Int) -> Bool {
        loopCount > 0
    }

    public static func nextFireDate(
        schedule: SessionLoopSchedule,
        from now: Date,
        calendar: Calendar
    ) -> Date {
        switch normalize(schedule) {
        case .interval(let seconds):
            return now.addingTimeInterval(TimeInterval(seconds))
        case .daily(let hour, let minute):
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            components.second = 0
            let today = calendar.date(from: components) ?? now
            if today > now { return today }
            return calendar.date(byAdding: .day, value: 1, to: today)
                ?? today.addingTimeInterval(86_400)
        }
    }

    public static func modelText(_ prompt: String) -> String {
        "到点了，执行「\(prompt)」。接着当前上下文做，不要寒暄。"
    }

    public static func intervalLabel(_ schedule: SessionLoopSchedule) -> String {
        switch normalize(schedule) {
        case .interval(let seconds):
            if seconds % 3600 == 0 {
                let hours = seconds / 3600
                return hours == 1 ? "每小时" : "每 \(hours) 小时"
            }
            let minutes = max(1, seconds / 60)
            return minutes == 1 ? "每分钟" : "每 \(minutes) 分钟"
        case .daily(let hour, let minute):
            return String(format: "每天 %02d:%02d", hour, minute)
        }
    }

    public static func title(from prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        let compact = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 28 { return compact }
        let end = compact.index(compact.startIndex, offsetBy: 27)
        return String(compact[..<end]) + "…"
    }

    public static func shortID(_ id: String) -> String {
        String(id.replacingOccurrences(of: "-", with: "").prefix(8))
    }

    public static func resolveID(_ query: String, in loops: [SessionLoop]) -> Result<SessionLoop, SessionLoopError> {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return .failure(.notFound) }
        if let exact = loops.first(where: { $0.id.lowercased() == needle }) {
            return .success(exact)
        }
        let compactNeedle = needle.replacingOccurrences(of: "-", with: "")
        let matches = loops.filter { loop in
            let compact = loop.id.lowercased().replacingOccurrences(of: "-", with: "")
            return compact == compactNeedle
                || compact.hasPrefix(compactNeedle)
                || shortID(loop.id).lowercased() == compactNeedle
        }
        if matches.count == 1, let match = matches.first { return .success(match) }
        if matches.count > 1 { return .failure(.ambiguousID) }
        return .failure(.notFound)
    }

    public static func pendingStatus(isBusy: Bool, hasQueuedUserFollowUp: Bool) -> String {
        if isBusy { return "待执行，等当前回复结束" }
        if hasQueuedUserFollowUp { return "待执行，等你的排队消息先走" }
        return "待执行"
    }

    public static func helpText() -> String {
        """
        /loop 5m 检查部署
        /loop 1h 看一下日志
        /loop 9:00 写日报
        /loop list
        /loop stop [id]
        """
    }

    public static func errorMessage(_ error: SessionLoopError) -> String {
        switch error {
        case .emptyPrompt:
            return "定时需要任务内容。例如 /loop 5m 检查部署。"
        case .invalidSchedule:
            return "间隔要写成 5m、1h 或 9:00。低于 1 分钟会提到 1 分钟。"
        case .sessionLimit:
            return "这个对话最多 \(maximumPerSession) 条定时。"
        case .notFound:
            return "没有这条定时。"
        case .noSession:
            return "还没有会话，稍后再设定时。"
        case .ambiguousID:
            return "有多条定时对上这个 id，请用完整 id 或右上角列表停止。"
        }
    }

    public static func consumeSchedule(_ raw: String) -> (schedule: SessionLoopSchedule, rest: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let daily = parsePrefixedDaily(trimmed) {
            return daily
        }
        let parts = splitOnce(trimmed)
        if let schedule = parseScheduleAtom(parts.head) {
            return (schedule, parts.tail)
        }
        return nil
    }

    private static func normalize(_ schedule: SessionLoopSchedule) -> SessionLoopSchedule {
        switch schedule {
        case .interval(let seconds):
            return .interval(seconds: raisedIntervalSeconds(seconds))
        case .daily(let hour, let minute):
            return .daily(hour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59))
        }
    }

    private static func parsePrefixedDaily(_ raw: String) -> (schedule: SessionLoopSchedule, rest: String)? {
        let lowered = raw.lowercased()
        for prefix in ["每天", "每日", "daily"] {
            guard lowered.hasPrefix(prefix) else { continue }
            let remainder = String(raw.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = splitOnce(remainder)
            if let schedule = parseClock(parts.head) {
                return (schedule, parts.tail)
            }
        }
        return nil
    }

    private static func parseScheduleAtom(_ raw: String) -> SessionLoopSchedule? {
        if let clock = parseClock(raw) { return clock }
        return parseInterval(raw)
    }

    private static func parseClock(_ raw: String) -> SessionLoopSchedule? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let colon = value.replacingOccurrences(of: "：", with: ":")
        if let separator = colon.firstIndex(of: ":") {
            let hourText = String(colon[..<separator])
            let minuteText = String(colon[colon.index(after: separator)...])
            if let hour = Int(hourText),
               let minute = Int(minuteText),
               minuteText.count == 2,
               (0...23).contains(hour),
               (0...59).contains(minute) {
                return .daily(hour: hour, minute: minute)
            }
        }
        if value.hasSuffix("点") {
            let hourText = String(value.dropLast())
            if let hour = Int(hourText), (0...23).contains(hour) {
                return .daily(hour: hour, minute: 0)
            }
        }
        return nil
    }

    private static func parseInterval(_ raw: String) -> SessionLoopSchedule? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let amount = leadingInt(value) else { return nil }
        let unit = String(value.drop(while: { $0.isNumber || $0.isWhitespace }))
        switch unit {
        case "s", "sec", "secs", "second", "seconds", "秒":
            return .interval(seconds: raisedIntervalSeconds(amount))
        case "m", "min", "mins", "minute", "minutes", "分钟":
            return .interval(seconds: raisedIntervalSeconds(amount * 60))
        case "h", "hr", "hrs", "hour", "hours", "小时":
            return .interval(seconds: raisedIntervalSeconds(amount * 3600))
        default:
            return nil
        }
    }

    private static func leadingInt(_ raw: String) -> Int? {
        let digits = raw.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    private static func splitOnce(_ raw: String) -> (head: String, tail: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = trimmed.firstIndex(where: \.isWhitespace) else {
            return (trimmed, "")
        }
        let head = String(trimmed[..<space])
        let tail = String(trimmed[trimmed.index(after: space)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (head, tail)
    }
}
