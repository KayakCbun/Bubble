import AVFoundation
import Foundation

final class RecordSeedAsrTranscriber: NSObject, RecordTranscriber, URLSessionWebSocketDelegate {
    private(set) var inputFormat: AVAudioFormat?
    private let credentials: RecordSeedAsrCredentials
    private var onCaptions: ((String) -> Void)?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let queue = DispatchQueue(label: "local.bubble.record-seed-asr")
    private var sequence: Int32 = 1
    private var ready = false
    private var finals = ""
    private var volatile = ""
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
        finals = ""
        volatile = ""
        sequence = 1
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
        task.resume()
        let hello = try RecordSeedAsrCodec.fullClientRequest(uid: "bubble-record")
        try await sendFrame(hello)
        sequence = 2
        ready = true
        OverlayLog.write("record transcriber ready engine=seed-asr format=16000Hz ch=1")
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func send(_ buffer: AVAudioPCMBuffer) {
        guard ready, let pcm = RecordAudioConvert.pcmInt16LE(buffer), !pcm.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.ready else { return }
            let sequence = self.sequence
            self.sequence += 1
            Task {
                do {
                    let frame = try RecordSeedAsrCodec.audioRequest(pcm, sequence: sequence, isLast: false)
                    try await self.sendFrame(frame)
                } catch {
                    OverlayLog.write("record seed-asr send failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func finalize() async -> String {
        ready = false
        let lastSequence = sequence
        do {
            let frame = try RecordSeedAsrCodec.audioRequest(Data(), sequence: lastSequence, isLast: true)
            try await sendFrame(frame)
        } catch {
            OverlayLog.write("record seed-asr last packet failed: \(error.localizedDescription)")
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        inputFormat = nil
        let notes = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        let finished = notes.isEmpty ? finals : notes
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
    }

    private func sendFrame(_ data: Data) async throws {
        guard let task else { throw RecordSeedAsrError.connect("not connected") }
        try await task.send(.data(data))
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
                return
            }
            let applied = RecordSeedAsrCodec.apply(response, finals: finals, volatile: volatile)
            finals = applied.finals
            volatile = applied.volatile
            let captions = applied.volatile
            DispatchQueue.main.async { [weak self] in
                self?.onCaptions?(captions)
            }
        } catch {
            OverlayLog.write("record seed-asr parse failed: \(error.localizedDescription)")
        }
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
