import AVFoundation
import Foundation

final class RecordSeedAsrTranscriber: NSObject, RecordTranscriber, URLSessionWebSocketDelegate {
    private(set) var inputFormat: AVAudioFormat?
    private let credentials: RecordSeedAsrCredentials
    private var onCaptions: ((String) -> Void)?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let sender = RecordSeedAsrSender()
    private var ready = false
    private var committed: [RecordSeedAsrCodec.Utterance] = []
    private var lastPreview = ""
    private var loggedSpeakerShape = false
    private var receiveTask: Task<Void, Never>?

    init(credentials: RecordSeedAsrCredentials, onCaptions: ((String) -> Void)? = nil) {
        self.credentials = credentials
        self.onCaptions = onCaptions
    }

    func start(locale: Locale) async throws {
        guard credentials.isUsable else { throw RecordSeedAsrError.missingCredentials }
        guard let format = RecordAudioConvert.seedAsrInputFormat() else {
            throw RecordCaptureError.converter
        }
        inputFormat = format
        committed = []
        lastPreview = ""
        let requestID = UUID().uuidString
        let connectID = UUID().uuidString
        let endpoint = credentials.endpoint.isEmpty ? RecordSeedAsrCodec.defaultEndpoint : credentials.endpoint
        guard let url = URL(string: endpoint) else {
            throw RecordSeedAsrError.connect(endpoint)
        }
        var request = URLRequest(url: url)
        for (key, value) in RecordSeedAsrCodec.headers(
            credentials: credentials,
            requestID: requestID,
            connectID: connectID
        ) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        await sender.attach(task)
        task.resume()
        let hello = try RecordSeedAsrCodec.fullClientRequest(uid: "bubble-record")
        try await sender.sendHello(hello)
        ready = true
        OverlayLog.write("record transcriber ready engine=seed-asr format=16000Hz ch=1")
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func send(_ buffer: AVAudioPCMBuffer) {
        guard ready, let pcm = RecordAudioConvert.pcmInt16LE(buffer), !pcm.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let sent = await self.sender.sendPCM(pcm)
            if !sent { self.ready = false }
        }
    }

    func finalize() async -> String {
        ready = false
        await sender.sendLast()
        try? await Task.sleep(nanoseconds: 400_000_000)
        receiveTask?.cancel()
        receiveTask = nil
        await sender.stop()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        inputFormat = nil
        let finished = lastPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        OverlayLog.write("record transcriber finished engine=seed-asr notes=\(finished.count)")
        return finished
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {}

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        OverlayLog.write("record seed-asr closed code=\(closeCode.rawValue)")
        ready = false
        Task { await sender.markDead() }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let task else { return }
            do {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .data(let payload):
                    data = payload
                case .string(let text):
                    data = Data(text.utf8)
                @unknown default:
                    continue
                }
                handle(data)
            } catch {
                if !Task.isCancelled {
                    OverlayLog.write("record seed-asr receive failed: \(error.localizedDescription)")
                    ready = false
                    await sender.markDead()
                }
                return
            }
        }
    }

    private func handle(_ data: Data) {
        do {
            let response = try RecordSeedAsrCodec.parse(data)
            if let message = response.errorMessage, response.messageType == RecordSeedAsrCodec.serverError {
                OverlayLog.write("record seed-asr error: \(message)")
                ready = false
                Task { await sender.markDead() }
                return
            }
            let applied = RecordSeedAsrCodec.apply(response, committed: committed)
            committed = applied.committed
            lastPreview = applied.preview
            if !loggedSpeakerShape, let sample = response.utterances.first(where: { $0.definite }) {
                loggedSpeakerShape = true
                OverlayLog.write(
                    "record seed-asr definite speaker=\(sample.speaker ?? "nil") start=\(sample.startMs.map(String.init) ?? "nil")"
                )
            }
            let captions = applied.preview
            DispatchQueue.main.async { [weak self] in
                self?.onCaptions?(captions)
            }
        } catch {
            OverlayLog.write("record seed-asr parse failed: \(error.localizedDescription)")
        }
    }
}

/// Seed ASR rejects a stream if websocket audio frames arrive out of sequence.
private actor RecordSeedAsrSender {
    private var task: URLSessionWebSocketTask?
    private var sequence: Int32 = 1
    private var alive = false
    private var loggedFailure = false

    func attach(_ task: URLSessionWebSocketTask) {
        self.task = task
        sequence = 1
        alive = true
        loggedFailure = false
    }

    func sendHello(_ data: Data) async throws {
        guard let task else { throw RecordSeedAsrError.connect("not connected") }
        try await task.send(.data(data))
        sequence = 2
    }

    func sendPCM(_ pcm: Data) async -> Bool {
        guard alive, let task else { return false }
        let seq = sequence
        sequence += 1
        do {
            let frame = try RecordSeedAsrCodec.audioRequest(pcm, sequence: seq, isLast: false)
            try await task.send(.data(frame))
            return true
        } catch {
            alive = false
            if !loggedFailure {
                loggedFailure = true
                OverlayLog.write("record seed-asr send failed: \(error.localizedDescription)")
            }
            return false
        }
    }

    func sendLast() async {
        guard let task else { return }
        let seq = sequence
        alive = false
        do {
            let frame = try RecordSeedAsrCodec.audioRequest(Data(), sequence: seq, isLast: true)
            try await task.send(.data(frame))
        } catch {
            OverlayLog.write("record seed-asr last packet failed: \(error.localizedDescription)")
        }
    }

    func markDead() {
        alive = false
    }

    func stop() {
        alive = false
        task = nil
    }
}

enum RecordTranscriberFactory {
    static func make(onCaptions: @escaping (String) -> Void) throws -> RecordTranscriber {
        let loaded = RecordSeedAsrCredentialsStore.load(file: OverlayPaths.recordFile)
        let choice = RecordEnginePolicy.resolve(
            configured: loaded.engine,
            seedAvailable: loaded.credentials.isUsable
        )
        switch choice {
        case .seedAsr:
            guard loaded.credentials.isUsable else { throw RecordSeedAsrError.missingCredentials }
            return RecordSeedAsrTranscriber(credentials: loaded.credentials, onCaptions: onCaptions)
        case .speechAnalyzer:
            return SpeechAnalyzerTranscriber(onCaptions: onCaptions)
        }
    }
}
