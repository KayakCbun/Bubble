import Foundation
import Network

private struct SteeringEndpoint: Decodable {
    var port: UInt16
    var token: String
    var generation: Int
}

private struct SteeringImageRequest: Encodable {
    var mimeType: String
    var data: String
}

private struct SteeringRequest: Encodable {
    var token: String
    var generation: Int
    var text: String
    var images: [SteeringImageRequest]
}

private struct SteeringResponse: Decodable {
    var ok: Bool
    var error: String?
}

enum SteeringControlError: LocalizedError {
    case unavailable
    case invalidEndpoint
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Steering is not available for this session yet."
        case .invalidEndpoint:
            return "The steering control endpoint is invalid."
        case .rejected(let message):
            return ["steer-unavailable", "steer-stale"].contains(message)
                ? "The turn finished before the message could be steered. It is still waiting."
                : "Could not steer the message: \(message)"
        }
    }
}

enum SteeringControlClient {
    static func send(sessionId: String, text: String, images: [PromptImage]) async throws {
        let endpoint = try await loadEndpoint(sessionId: sessionId)
        let request = SteeringRequest(
            token: endpoint.token,
            generation: endpoint.generation,
            text: text,
            images: images.map {
                SteeringImageRequest(mimeType: $0.mimeType, data: $0.data.base64EncodedString())
            }
        )
        guard var data = try? JSONEncoder().encode(request) else {
            throw SteeringControlError.invalidEndpoint
        }
        data.append(0x0A)
        try await exchange(port: endpoint.port, request: data)
    }

    private static func loadEndpoint(sessionId: String) async throws -> SteeringEndpoint {
        let url = OverlayPaths.steeringControlFile(sessionId: sessionId)
        for attempt in 0..<6 {
            if let data = try? Data(contentsOf: url),
               let endpoint = try? JSONDecoder().decode(SteeringEndpoint.self, from: data),
               endpoint.port > 0,
               !endpoint.token.isEmpty {
                return endpoint
            }
            if attempt < 5 {
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        throw SteeringControlError.unavailable
    }

    private static func exchange(port: UInt16, request: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "local.bubble.steering-client")
            let connection = NWConnection(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            var finished = false
            func finish(_ result: Result<Void, Error>) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { error in
                        if let error {
                            queue.async { finish(.failure(error)) }
                            return
                        }
                        receiveResponse(connection, buffer: Data(), queue: queue, finish: finish)
                    })
                case .failed(let error):
                    finish(.failure(error))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) {
                finish(.failure(SteeringControlError.unavailable))
            }
        }
    }

    private static func receiveResponse(
        _ connection: NWConnection,
        buffer: Data,
        queue: DispatchQueue,
        finish: @escaping (Result<Void, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64_000) { data, _, complete, error in
            if let error {
                queue.async { finish(.failure(error)) }
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if let newline = next.range(of: Data([0x0A])) {
                let line = next.subdata(in: next.startIndex..<newline.lowerBound)
                guard let response = try? JSONDecoder().decode(SteeringResponse.self, from: line) else {
                    finish(.failure(SteeringControlError.invalidEndpoint))
                    return
                }
                if response.ok {
                    finish(.success(()))
                } else {
                    finish(.failure(SteeringControlError.rejected(response.error ?? "unknown error")))
                }
                return
            }
            if complete {
                finish(.failure(SteeringControlError.invalidEndpoint))
                return
            }
            receiveResponse(connection, buffer: next, queue: queue, finish: finish)
        }
    }
}
