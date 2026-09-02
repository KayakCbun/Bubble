import AVFoundation
import Foundation
import Speech

final class RecordController: RecordCaptureDelegate {
    static let shared = RecordController()

    private(set) var ownerRuntimeID: UUID?
    private(set) var startedAt: Date?
    private(set) var liveNotes = ""
    private var capture: RecordCapture?
    private var transcriber: RecordTranscriber?
    private var recordEngine: RecordEngineChoice?
    private var recordID: String?
    private weak var ownerStore: ChatStore?

    var isRecording: Bool { ownerRuntimeID != nil }

    func owns(_ runtimeID: UUID) -> Bool {
        ownerRuntimeID == runtimeID
    }

    func start(store: ChatStore) async throws {
        if isRecording { throw RecordError.alreadyRecording }
        ownerStore = store
        ownerRuntimeID = store.runtimeID
        startedAt = Date()
        recordID = UUID().uuidString
        liveNotes = ""
        store.beginLiveRecord()
        do {
            let transcriber = try RecordTranscriberFactory.make { [weak self] notes in
                DispatchQueue.main.async {
                    self?.liveNotes = notes
                    self?.ownerStore?.updateLiveRecordNotes(notes)
                }
            }
            let usingSeed = transcriber is RecordSeedAsrTranscriber
            recordEngine = usingSeed ? .seedAsr : .speechAnalyzer
            try await requestPermissions(usingSeedASR: usingSeed)
            let locale = Locale.preferredLanguages.first.map(Locale.init(identifier:)) ?? .current
            try await transcriber.start(locale: locale)
            let capture = RecordCapture()
            capture.outputFormat = transcriber.inputFormat
            capture.delegate = self
            try await capture.start()
            self.capture = capture
            self.transcriber = transcriber
        } catch {
            OverlayLog.write("record start failed: \(error.localizedDescription)")
            store.endLiveRecord()
            ownerRuntimeID = nil
            ownerStore = nil
            startedAt = nil
            recordID = nil
            recordEngine = nil
            throw error
        }
    }

    func stop(store: ChatStore) async -> RecordStopOutcome {
        guard owns(store.runtimeID) else {
            return RecordStopOutcome(plan: nil, durationSeconds: 0)
        }
        let startedAt = startedAt ?? Date()
        let recordID = recordID ?? UUID().uuidString
        await capture?.stop()
        capture = nil
        let notes = await transcriber?.finalize() ?? liveNotes
        transcriber = nil
        recordEngine = nil
        ownerRuntimeID = nil
        ownerStore = nil
        self.startedAt = nil
        self.recordID = nil
        liveNotes = ""
        store.endLiveRecord()
        let duration = Date().timeIntervalSince(startedAt)
        return RecordStopOutcome(
            plan: RecordPolicy.flushPlan(
                notes: notes,
                duration: duration,
                recordID: recordID
            ),
            durationSeconds: max(0, Int(duration.rounded()))
        )
    }

    func recordCaptureDidOutput(_ buffer: AVAudioPCMBuffer) {
        transcriber?.send(buffer)
    }

    func recordCaptureDidFail(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.ownerStore?.failLiveRecord(error)
            Task { _ = await self.stopIfOwned() }
        }
    }

    private func stopIfOwned() async -> RecordStopOutcome {
        guard let ownerStore else {
            return RecordStopOutcome(plan: nil, durationSeconds: 0)
        }
        return await stop(store: ownerStore)
    }

    private func requestPermissions(usingSeedASR: Bool) async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            guard mic else { throw RecordPermissionError.microphone }
        default:
            throw RecordPermissionError.microphone
        }
        guard !usingSeedASR else { return }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            let speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            guard speech == .authorized else { throw RecordPermissionError.speech }
        default:
            throw RecordPermissionError.speech
        }
    }
}

enum RecordPermissionError: Error, LocalizedError {
    case microphone
    case speech

    var errorDescription: String? {
        switch self {
        case .microphone:
            return "Bubble needs the microphone so Record notes include your side of the meeting."
        case .speech:
            return "Bubble needs Speech Recognition to caption Record audio on this Mac."
        }
    }
}
