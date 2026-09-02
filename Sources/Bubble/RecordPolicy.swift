import Foundation

enum RecordCommand: Equatable, Sendable {
    case toggle
    case start
    case stop
    case help
}

enum RecordError: Error, Equatable, Sendable {
    case alreadyRecording
    case notRecording
}

enum RecordEngine: String, Equatable, Sendable {
    case auto
    case seedAsr = "seed-asr"
    case speechAnalyzer = "speech-analyzer"

    static func parse(_ raw: String?) -> RecordEngine {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "seed-asr", "seedasr", "doubao", "volc":
            return .seedAsr
        case "speech-analyzer", "speech", "apple", "local":
            return .speechAnalyzer
        default:
            return .auto
        }
    }
}

enum RecordEngineChoice: Equatable, Sendable {
    case seedAsr
    case speechAnalyzer
}

struct RecordSeedAsrCredentials: Equatable, Sendable {
    var apiKey: String = ""
    var appId: String = ""
    var accessToken: String = ""
    var resourceId: String = "volc.seedasr.sauc.duration"
    var endpoint: String = "wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_async"

    var isUsable: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (!appId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

enum RecordEnginePolicy {
    static func resolve(configured: RecordEngine, seedAvailable: Bool) -> RecordEngineChoice {
        switch configured {
        case .speechAnalyzer:
            return .speechAnalyzer
        case .seedAsr:
            return .seedAsr
        case .auto:
            return seedAvailable ? .seedAsr : .speechAnalyzer
        }
    }
}

enum RecordNotesAssembler {
    static func appendFinal(existing: String, incoming: String) -> String {
        let text = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return existing }
        if existing.isEmpty { return text }
        if existing.hasSuffix(text) { return existing }
        if existing.hasSuffix(" ") || text.hasPrefix(" ") {
            return existing + text
        }
        return existing + " " + text
    }

    static func merge(final: String, volatile: String) -> String {
        if final.isEmpty { return volatile }
        if volatile.isEmpty { return final }
        if volatile.hasPrefix(final) { return volatile }
        return final + (final.hasSuffix(" ") || volatile.hasPrefix(" ") ? "" : " ") + volatile
    }
}

enum RecordToggleAction: Equatable, Sendable {
    case start
    case stop
    case rejectAlreadyRecording
}

enum RecordCloseIntent: Equatable, Sendable {
    case closeSideSession
    case startFresh
}

struct RecordClosePrompt: Equatable, Sendable {
    var intent: RecordCloseIntent

    var title: String {
        switch intent {
        case .closeSideSession:
            return "关掉这个对话？"
        case .startFresh:
            return "开始新对话？"
        }
    }

    var message: String {
        switch intent {
        case .closeSideSession:
            return "录音还在进行。关掉后会停止录音，并把录音笔记写进这个对话。"
        case .startFresh:
            return "录音还在进行。开始新对话前会停止录音，并把录音笔记写进当前对话。"
        }
    }

    var confirmTitle: String {
        switch intent {
        case .closeSideSession:
            return "停止录音并关掉"
        case .startFresh:
            return "停止录音并新开"
        }
    }
}

struct RecordFlushPlan: Equatable, Sendable {
    var notes: String
    var displayText: String
    var relativeFilePath: String?
    var durationSeconds: Int
}

struct RecordStopOutcome: Equatable, Sendable {
    var plan: RecordFlushPlan?
    var durationSeconds: Int
}

enum RecordPolicy {
    static let liveCaptionLineLimit = 4
    static let notesFileCharacterThreshold = 32_000
    static let notesFilePreviewCharacters = 2_000

    static func parseCommand(_ args: String) -> RecordCommand {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .toggle }
        let token = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
        switch token {
        case "start", "on":
            return .start
        case "stop", "off", "end":
            return .stop
        case "help", "?":
            return .help
        default:
            return .help
        }
    }

    static func toggleAction(isRecording: Bool, ownerIsCurrentSession: Bool) -> RecordToggleAction {
        if !isRecording { return .start }
        if ownerIsCurrentSession { return .stop }
        return .rejectAlreadyRecording
    }

    static func startAction(isRecording: Bool, ownerIsCurrentSession: Bool) -> Result<Void, RecordError> {
        if !isRecording { return .success(()) }
        if ownerIsCurrentSession { return .failure(.alreadyRecording) }
        return .failure(.alreadyRecording)
    }

    static func stopAction(isRecording: Bool, ownerIsCurrentSession: Bool) -> Result<Void, RecordError> {
        if isRecording, ownerIsCurrentSession { return .success(()) }
        return .failure(.notRecording)
    }

    static func hideKeepsRunning() -> Bool { true }

    static func shouldConfirmClose(isRecording: Bool, hasNotes: Bool) -> Bool {
        isRecording && hasNotes
    }

    static func shouldFlushOnClose(isRecording: Bool) -> Bool {
        isRecording
    }

    static func shouldQueueFlush(isBusy: Bool) -> Bool {
        isBusy
    }

    static func liveCaptionPreview(_ notes: String) -> String {
        let lines = notes
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        let kept = Array(lines.suffix(liveCaptionLineLimit))
        return kept.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let liveElapsedTickSeconds: TimeInterval = 1
    static let microphoneSilencePeak: Float = 0.012

    static func shouldSendMicrophone(peak: Float) -> Bool {
        peak.isFinite && peak >= microphoneSilencePeak && peak <= 1.5
    }

    static func noNotesMessage(durationSeconds: Int) -> String {
        "录音了 \(durationLabel(max(durationSeconds, 0)))，没有识别到能写进对话的语音。"
    }

    static func elapsedClockLabel(seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    static func elapsedClockLabel(since startedAt: Date, now: Date) -> String {
        elapsedClockLabel(seconds: Int(now.timeIntervalSince(startedAt)))
    }

    static func flushPlan(
        notes: String,
        duration: TimeInterval,
        recordID: String
    ) -> RecordFlushPlan? {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let seconds = max(0, Int(duration.rounded()))
        let heading = "录音笔记（\(durationLabel(seconds))）"
        if trimmed.count > notesFileCharacterThreshold {
            let fileName = sanitizedFileName(recordID)
            let relative = "records/\(fileName).md"
            let preview = String(trimmed.prefix(notesFilePreviewCharacters))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let display = """
            \(heading)。全文在 \(relative)，下一句可以用 @\(relative)。

            \(preview)
            """
            return RecordFlushPlan(
                notes: trimmed,
                displayText: display,
                relativeFilePath: relative,
                durationSeconds: seconds
            )
        }
        return RecordFlushPlan(
            notes: trimmed,
            displayText: "\(heading)\n\n\(trimmed)",
            relativeFilePath: nil,
            durationSeconds: seconds
        )
    }

    static func durationLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(max(seconds, 0)) 秒" }
        let minutes = seconds / 60
        return "\(minutes) 分钟"
    }

    static func helpText() -> String {
        """
        /record — 开始给当前对话录音（系统声音 + 麦克风）。
        /record — 再输入一次停止，并把录音笔记写进对话。
        /record stop — 停止录音。
        隐藏 Bubble 不会停止录音。关掉或新开对话会先停下并写入笔记。
        已配置豆包 Seed ASR 时用云端流式识别做直播字幕；否则用本机 Apple Speech。
        """
    }

    static func errorMessage(_ error: RecordError) -> String {
        switch error {
        case .alreadyRecording:
            return "已经在另一个对话里录音。先停掉那边，再在这里开始。"
        case .notRecording:
            return "现在没有录音。"
        }
    }

    private static func sanitizedFileName(_ recordID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let filtered = recordID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let name = String(filtered).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return name.isEmpty ? UUID().uuidString : name
    }
}
