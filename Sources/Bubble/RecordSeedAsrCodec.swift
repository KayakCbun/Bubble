import Foundation
import zlib

enum RecordSeedAsrCodec {
    static let protocolVersion: UInt8 = 0b0001
    static let headerSizeUnits: UInt8 = 0b0001
    static let clientFullRequest: UInt8 = 0b0001
    static let clientAudioOnly: UInt8 = 0b0010
    static let serverFullResponse: UInt8 = 0b1001
    static let serverAck: UInt8 = 0b1011
    static let serverError: UInt8 = 0b1111
    static let flagPositiveSequence: UInt8 = 0b0001
    static let flagNegativeSequence: UInt8 = 0b0011
    static let serialJSON: UInt8 = 0b0001
    static let serialNone: UInt8 = 0b0000
    static let compressionGzip: UInt8 = 0b0001

    static let defaultEndpoint = "wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_async"
    static let defaultResourceId = "volc.seedasr.sauc.duration"

    struct Utterance: Equatable {
        var text: String
        var definite: Bool
        var startMs: Int?
        var endMs: Int?
        var speaker: String?
    }

    struct Response: Equatable {
        var messageType: UInt8
        var sequence: Int32?
        var isLast: Bool
        var text: String?
        var utterances: [Utterance]
        var code: Int?
        var errorMessage: String?
    }

    static func headers(credentials: RecordSeedAsrCredentials, requestID: String, connectID: String) -> [String: String] {
        var headers = [
            "X-Api-Resource-Id": credentials.resourceId.isEmpty ? defaultResourceId : credentials.resourceId,
            "X-Api-Request-Id": requestID,
            "X-Api-Connect-Id": connectID,
        ]
        let apiKey = credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            headers["X-Api-Key"] = apiKey
        } else {
            headers["X-Api-App-Key"] = credentials.appId
            headers["X-Api-Access-Key"] = credentials.accessToken
        }
        return headers
    }

    static func fullClientRequest(uid: String, sequence: Int32 = 1) throws -> Data {
        let payload: [String: Any] = [
            "user": ["uid": uid],
            "audio": [
                "format": "pcm",
                "rate": 16_000,
                "bits": 16,
                "channel": 1,
                "codec": "raw",
            ],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
                "enable_ddc": true,
                "enable_speaker_info": true,
                "show_utterances": true,
                "result_type": "single",
                "enable_nonstream": true,
                "ssd_version": "200",
                "end_window_size": 800,
            ],
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        let compressed = try gzip(json)
        return frame(
            messageType: clientFullRequest,
            flags: flagPositiveSequence,
            serialization: serialJSON,
            sequence: sequence,
            payload: compressed
        )
    }

    static func audioRequest(_ pcm: Data, sequence: Int32, isLast: Bool) throws -> Data {
        let compressed = try gzip(pcm)
        return frame(
            messageType: clientAudioOnly,
            flags: isLast ? flagNegativeSequence : flagPositiveSequence,
            serialization: serialNone,
            sequence: isLast ? -sequence : sequence,
            payload: compressed
        )
    }

    static func parse(_ data: Data) throws -> Response {
        guard data.count >= 4 else {
            throw RecordSeedAsrError.truncatedFrame
        }
        let bytes = [UInt8](data)
        let headerBytes = Int(bytes[0] & 0x0F) * 4
        let messageType = bytes[1] >> 4
        let flags = bytes[1] & 0x0F
        let compression = bytes[2] & 0x0F
        let hasSequence = (flags & 0x01) != 0
        let isLast = (flags & 0x02) != 0
        var offset = headerBytes
        var sequence: Int32?
        if hasSequence {
            guard data.count >= offset + 4 else { throw RecordSeedAsrError.truncatedFrame }
            sequence = int32(data, offset)
            offset += 4
        }
        if messageType == serverError {
            guard data.count >= offset + 8 else { throw RecordSeedAsrError.truncatedFrame }
            let code = Int(uint32(data, offset))
            let size = Int(uint32(data, offset + 4))
            offset += 8
            let messageData = data.subdata(in: offset..<(offset + min(size, data.count - offset)))
            let raw = compression == compressionGzip ? (try? gunzip(messageData)) ?? messageData : messageData
            return Response(
                messageType: messageType,
                sequence: sequence,
                isLast: isLast,
                text: nil,
                utterances: [],
                code: code,
                errorMessage: String(data: raw, encoding: .utf8)
            )
        }
        guard data.count >= offset + 4 else {
            return Response(messageType: messageType, sequence: sequence, isLast: isLast, text: nil, utterances: [], code: nil, errorMessage: nil)
        }
        let size = Int(uint32(data, offset))
        offset += 4
        guard size >= 0, data.count >= offset + size else {
            throw RecordSeedAsrError.truncatedFrame
        }
        var payload = data.subdata(in: offset..<(offset + size))
        if compression == compressionGzip, !payload.isEmpty {
            payload = try gunzip(payload)
        }
        if messageType == serverAck {
            let json = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any]) ?? [:]
            return Response(
                messageType: messageType,
                sequence: sequence,
                isLast: isLast,
                text: nil,
                utterances: [],
                code: json["code"] as? Int,
                errorMessage: json["message"] as? String
            )
        }
        let json = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any]) ?? [:]
        let result = json["result"] as? [String: Any]
        let text = result?["text"] as? String
        let resultSpeaker = speakerValue(in: result) ?? speakerValue(in: json)
        let rawUtterances = result?["utterances"] as? [[String: Any]] ?? []
        let utterances = rawUtterances.compactMap { item -> Utterance? in
            guard var utterance = parseUtterance(item) else { return nil }
            if utterance.speaker == nil { utterance.speaker = resultSpeaker }
            return utterance
        }
        return Response(
            messageType: messageType,
            sequence: sequence,
            isLast: isLast,
            text: text,
            utterances: utterances,
            code: json["code"] as? Int,
            errorMessage: json["message"] as? String
        )
    }

    static func apply(
        _ response: Response,
        committed: [Utterance]
    ) -> (committed: [Utterance], preview: String) {
        var next = committed
        var volatile: Utterance?
        if !response.utterances.isEmpty {
            for utterance in response.utterances {
                let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                var item = utterance
                item.text = text
                if item.definite {
                    next = upsert(next, item)
                } else {
                    volatile = item
                }
            }
        } else if let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            volatile = Utterance(text: text, definite: false)
        }
        let preview = RecordNotesAssembler.captionNotes(
            (next + [volatile].compactMap { $0 }).map {
                RecordNotesAssembler.captionLine(
                    text: $0.text,
                    speaker: $0.speaker,
                    startMs: $0.startMs,
                    endMs: $0.endMs
                )
            }
        )
        return (next, preview)
    }

    static func parseUtterance(_ item: [String: Any]) -> Utterance? {
        guard let text = item["text"] as? String else { return nil }
        return Utterance(
            text: text,
            definite: boolValue(item["definite"]),
            startMs: intValue(item["start_time"]),
            endMs: intValue(item["end_time"]),
            speaker: speakerValue(in: item)
        )
    }

    static func upsert(_ committed: [Utterance], _ item: Utterance) -> [Utterance] {
        if let start = item.startMs,
           let index = committed.firstIndex(where: { abs(($0.startMs ?? -10_000) - start) < 250 }) {
            var merged = item
            if merged.speaker == nil { merged.speaker = committed[index].speaker }
            var next = committed
            next[index] = merged
            return next
        }
        if let last = committed.last, last.text == item.text {
            var merged = item
            if merged.speaker == nil { merged.speaker = last.speaker }
            var next = committed
            next[next.count - 1] = merged
            return next
        }
        return committed + [item]
    }

    static func speakerValue(in object: [String: Any]?) -> String? {
        guard let object else { return nil }
        let keys = ["speaker", "speaker_id", "spk", "spk_id", "speakerId"]
        for key in keys {
            if let value = stringValue(object[key]) { return value }
        }
        if let additions = object["additions"] as? [String: Any] {
            for key in keys {
                if let value = stringValue(additions[key]) { return value }
            }
        }
        if let additions = object["additions"] as? String,
           let data = additions.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in keys {
                if let value = stringValue(parsed[key]) { return value }
            }
        }
        if let words = object["words"] as? [[String: Any]] {
            let speakers = words.compactMap { speakerValue(in: $0) }
            if let majority = majority(speakers) { return majority }
        }
        return nil
    }

    private static func majority(_ values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed == "true" || trimmed == "1"
        }
        return false
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        if let number = value as? Double { return Int(number) }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func frame(
        messageType: UInt8,
        flags: UInt8,
        serialization: UInt8,
        sequence: Int32,
        payload: Data
    ) -> Data {
        var data = Data(count: 4)
        data[0] = (protocolVersion << 4) | headerSizeUnits
        data[1] = (messageType << 4) | flags
        data[2] = (serialization << 4) | compressionGzip
        data[3] = 0
        var seq = sequence.bigEndian
        data.append(Data(bytes: &seq, count: 4))
        var size = UInt32(payload.count).bigEndian
        data.append(Data(bytes: &size, count: 4))
        data.append(payload)
        return data
    }

    private static func int32(_ data: Data, _ offset: Int) -> Int32 {
        Int32(bitPattern: uint32(data, offset))
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        let bytes = [UInt8](data.subdata(in: offset..<(offset + 4)))
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }

    static func gzip(_ data: Data) throws -> Data {
        try zlib(data, windowBits: 15 + 16, decompressing: false)
    }

    static func gunzip(_ data: Data) throws -> Data {
        try zlib(data, windowBits: 15 + 16, decompressing: true)
    }

    private static func zlib(_ data: Data, windowBits: Int32, decompressing: Bool) throws -> Data {
        if data.isEmpty, decompressing { return Data() }
        var input = data.isEmpty ? [UInt8](repeating: 0, count: 1) : [UInt8](data)
        var stream = z_stream()
        let initStatus: Int32 = {
            if decompressing {
                return inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            }
            return deflateInit2_(
                &stream,
                Z_DEFAULT_COMPRESSION,
                Z_DEFLATED,
                windowBits,
                8,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
        }()
        guard initStatus == Z_OK else { throw RecordSeedAsrError.gzip }
        defer {
            if decompressing {
                inflateEnd(&stream)
            } else {
                deflateEnd(&stream)
            }
        }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: max(64, data.count * 2))
        try input.withUnsafeMutableBytes { inRaw in
            stream.next_in = inRaw.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(data.count)
            var status: Int32
            repeat {
                let capacity = buffer.count
                status = buffer.withUnsafeMutableBytes { raw -> Int32 in
                    stream.next_out = raw.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(capacity)
                    if decompressing {
                        return inflate(&stream, Z_FINISH)
                    }
                    return deflate(&stream, Z_FINISH)
                }
                let produced = capacity - Int(stream.avail_out)
                if produced > 0 {
                    output.append(buffer, count: produced)
                }
                if status == Z_STREAM_END { break }
                if status != Z_OK && status != Z_BUF_ERROR {
                    throw RecordSeedAsrError.gzip
                }
            } while status != Z_STREAM_END
        }
        return output
    }
}

enum RecordSeedAsrError: Error, LocalizedError {
    case missingCredentials
    case truncatedFrame
    case gzip
    case connect(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Record 要用豆包 Seed ASR 2.0。在 ~/.bubble/record.json 写入 apiKey，或设置 ARK_API_KEY / VOLC_ASR_API_KEY。"
        case .truncatedFrame:
            return "Seed ASR returned a truncated frame."
        case .gzip:
            return "Seed ASR gzip failed."
        case .connect(let message):
            return "Seed ASR 连不上：\(message)"
        case .server(let message):
            return "Seed ASR 失败：\(message)"
        }
    }
}
