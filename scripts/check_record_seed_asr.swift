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

        let emptyGzip = try RecordSeedAsrCodec.gzip(Data())
        let emptyRestored = try RecordSeedAsrCodec.gunzip(emptyGzip)
        expect(!emptyGzip.isEmpty, "the last empty audio packet still has a gzip header")
        expect(emptyRestored.isEmpty, "empty gzip round-trips to empty audio")
    }

    private static func testFullRequestFrame() throws {
        let frame = try RecordSeedAsrCodec.fullClientRequest(uid: "bubble")
        expect(frame.count > 12, "full client request has header, sequence, and payload")
        expect(frame[1] >> 4 == RecordSeedAsrCodec.clientFullRequest, "first client packet is a full request")
        expect(frame[2] & 0x0F == RecordSeedAsrCodec.compressionGzip, "client packets are gzipped")
        let size = Int(UInt32(bigEndian: frame.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self) }))
        let payload = try RecordSeedAsrCodec.gunzip(frame.subdata(in: 12..<(12 + size)))
        let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let request = json?["request"] as? [String: Any]
        expect(request?["show_utterances"] as? Bool == true, "Seed ASR requests utterance timestamps")
        expect(request?["enable_speaker_info"] as? Bool == true, "Seed ASR requests speaker labels")
        expect(request?["result_type"] as? String == "single", "incremental utterances keep live captions")
        expect(request?["enable_nonstream"] as? Bool == true, "speaker labels need dual-pass on the async endpoint")
        expect(request?["ssd_version"] as? String == "200", "speaker labels use the Seed ASR 2.0 SSD")
        let audio = json?["audio"] as? [String: Any]
        expect(audio?["language"] == nil, "language stays unpinned so Cantonese still transcribes")
    }

    private static func testAudioLastSequence() throws {
        let frame = try RecordSeedAsrCodec.audioRequest(Data([0, 1, 2, 3]), sequence: 4, isLast: true)
        let seq = Int32(bigEndian: frame.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: Int32.self) })
        expect(seq == -4, "the last audio packet negates its sequence")
        expect(frame[1] & 0x0F == RecordSeedAsrCodec.flagNegativeSequence, "the last audio packet is marked last")
    }

    private static func testApplyCaptions() {
        let parsed = RecordSeedAsrCodec.parseUtterance([
            "text": "你好世界",
            "definite": true,
            "start_time": 1200,
            "end_time": 3400,
            "additions": ["speaker": "1"],
        ])
        expect(parsed?.speaker == "1", "utterances keep the speaker id")
        expect(parsed?.startMs == 1200, "utterances keep the start time")
        expect(parsed?.endMs == 3400, "utterances keep the end time")
        expect(
            RecordSeedAsrCodec.parseUtterance([
                "text": "你好",
                "definite": true,
                "speaker_id": 2,
            ])?.speaker == "2",
            "numeric speaker_id still labels the line"
        )
        expect(
            RecordSeedAsrCodec.parseUtterance([
                "text": "你好",
                "definite": true,
                "words": [["text": "你", "additions": ["speaker": "3"]]],
            ])?.speaker == "3",
            "speaker labels on words still lift to the utterance"
        )

        let first = RecordSeedAsrCodec.apply(
            RecordSeedAsrCodec.Response(
                messageType: RecordSeedAsrCodec.serverFullResponse,
                sequence: 1,
                isLast: false,
                text: "你好",
                utterances: [
                    RecordSeedAsrCodec.Utterance(
                        text: "你好",
                        definite: false,
                        startMs: 0,
                        endMs: 1_500,
                        speaker: "1"
                    ),
                ],
                code: 0,
                errorMessage: nil
            ),
            committed: []
        )
        expect(first.preview == "[0:00–0:01] 说话人1 你好", "indefinite utterances are live captions with time and speaker")
        expect(first.committed.isEmpty, "indefinite utterances are not flushed yet")

        let second = RecordSeedAsrCodec.apply(
            RecordSeedAsrCodec.Response(
                messageType: RecordSeedAsrCodec.serverFullResponse,
                sequence: 2,
                isLast: false,
                text: "你好世界",
                utterances: [
                    RecordSeedAsrCodec.Utterance(
                        text: "你好世界",
                        definite: true,
                        startMs: 0,
                        endMs: 1800,
                        speaker: "1"
                    ),
                ],
                code: 0,
                errorMessage: nil
            ),
            committed: first.committed
        )
        expect(
            second.preview == "[0:00–0:01] 说话人1 你好世界",
            "definite utterances become Record notes with a time range"
        )
        expect(second.committed.count == 1, "definite utterances stay committed")

        let relabeled = RecordSeedAsrCodec.apply(
            RecordSeedAsrCodec.Response(
                messageType: RecordSeedAsrCodec.serverFullResponse,
                sequence: 3,
                isLast: false,
                text: "你好世界 下一位",
                utterances: [
                    RecordSeedAsrCodec.Utterance(
                        text: "你好世界",
                        definite: true,
                        startMs: 0,
                        endMs: 1800,
                        speaker: "2"
                    ),
                    RecordSeedAsrCodec.Utterance(
                        text: "下一位",
                        definite: true,
                        startMs: 2_000,
                        endMs: 3_100,
                        speaker: "1"
                    ),
                ],
                code: 0,
                errorMessage: nil
            ),
            committed: second.committed
        )
        expect(relabeled.committed.count == 2, "a full result list keeps earlier utterances")
        expect(relabeled.committed.first?.speaker == "2", "later clustering can update the speaker")
        expect(
            relabeled.preview.contains("说话人1 下一位") == true,
            "a second speaker is labeled on its own line"
        )
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
