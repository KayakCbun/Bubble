import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
enum RecordSeedAsrCheck {
    static func main() throws {
        testHeaders()
        try testGzipRoundTrip()
        try testFullRequestFrame()
        try testAudioLastSequence()
        testApplyCaptions()
        testCredentialsStore()
        print("record seed asr codec checks passed")
    }

    private static func testHeaders() {
        let keyHeaders = RecordSeedAsrCodec.headers(
            credentials: RecordSeedAsrCredentials(apiKey: "ark-key"),
            requestID: "req",
            connectID: "conn"
        )
        expect(keyHeaders["X-Api-Key"] == "ark-key", "API key auth uses X-Api-Key")
        expect(keyHeaders["X-Api-Resource-Id"] == "volc.seedasr.sauc.duration", "Seed ASR 2.0 duration resource")
        expect(keyHeaders["X-Api-App-Key"] == nil, "API key auth does not send app id")

        let appHeaders = RecordSeedAsrCodec.headers(
            credentials: RecordSeedAsrCredentials(appId: "app", accessToken: "token"),
            requestID: "req",
            connectID: "conn"
        )
        expect(appHeaders["X-Api-App-Key"] == "app", "legacy auth sends app id")
        expect(appHeaders["X-Api-Access-Key"] == "token", "legacy auth sends access token")
    }

    private static func testGzipRoundTrip() throws {
        let source = Data("hello seed asr".utf8)
        let compressed = try RecordSeedAsrCodec.gzip(source)
        let restored = try RecordSeedAsrCodec.gunzip(compressed)
        expect(restored == source, "gzip round-trips")
    }

    private static func testFullRequestFrame() throws {
        let frame = try RecordSeedAsrCodec.fullClientRequest(uid: "bubble")
        expect(frame.count > 12, "full client request has header, sequence, and payload")
        expect(frame[1] >> 4 == RecordSeedAsrCodec.clientFullRequest, "first client packet is a full request")
        expect(frame[2] & 0x0F == RecordSeedAsrCodec.compressionGzip, "client packets are gzipped")
    }

    private static func testAudioLastSequence() throws {
        let frame = try RecordSeedAsrCodec.audioRequest(Data([0, 1, 2, 3]), sequence: 4, isLast: true)
        let seq = Int32(bigEndian: frame.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: Int32.self) })
        expect(seq == -4, "the last audio packet negates its sequence")
        expect(frame[1] & 0x0F == RecordSeedAsrCodec.flagNegativeSequence, "the last audio packet is marked last")
    }

    private static func testApplyCaptions() {
        let first = RecordSeedAsrCodec.apply(
            RecordSeedAsrCodec.Response(
                messageType: RecordSeedAsrCodec.serverFullResponse,
                sequence: 1,
                isLast: false,
                text: "你好",
                utterances: [RecordSeedAsrCodec.Utterance(text: "你好", definite: false)],
                code: 0,
                errorMessage: nil
            ),
            finals: "",
            volatile: ""
        )
        expect(first.volatile == "你好", "indefinite utterances are live captions")
        expect(first.finals.isEmpty, "indefinite utterances are not flushed yet")

        let second = RecordSeedAsrCodec.apply(
            RecordSeedAsrCodec.Response(
                messageType: RecordSeedAsrCodec.serverFullResponse,
                sequence: 2,
                isLast: false,
                text: "你好世界",
                utterances: [RecordSeedAsrCodec.Utterance(text: "你好世界", definite: true)],
                code: 0,
                errorMessage: nil
            ),
            finals: first.finals,
            volatile: first.volatile
        )
        expect(second.finals == "你好世界", "definite utterances become Record notes")
    }

    private static func testCredentialsStore() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("record.json")
        try! Data(#"{"engine":"seed-asr","apiKey":"from-file"}"#.utf8).write(to: file)
        let loaded = RecordSeedAsrCredentialsStore.load(
            environment: ["ARK_API_KEY": "from-env"],
            file: file
        )
        expect(loaded.engine == .seedAsr, "record.json can pin Seed ASR")
        expect(loaded.credentials.apiKey == "from-env", "environment API keys win over the file")
        let fileOnly = RecordSeedAsrCredentialsStore.load(environment: [:], file: file)
        expect(fileOnly.credentials.apiKey == "from-file", "record.json supplies the key when env is empty")
    }
}
