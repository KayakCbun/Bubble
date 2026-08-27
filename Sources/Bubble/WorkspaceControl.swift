import BubbleMounts
import Foundation
import Network

final class WorkspaceControlServer: @unchecked Sendable {
    var handler: (@Sendable (String, [String: Any]) async throws -> [String: Any])?

    private let queue = DispatchQueue(label: "local.bubble.workspace-control")
    private var listener: NWListener?
    private var token = UUID().uuidString
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let controlFile: URL

    init(controlFile: URL = OverlayPaths.controlFile) {
        self.controlFile = controlFile
    }

    func start() {
        queue.async { [weak self] in
            self?.startLocked()
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for connection in connections.values {
                connection.cancel()
            }
            connections.removeAll()
            try? FileManager.default.removeItem(at: controlFile)
        }
    }

    private func startLocked() {
        listener?.cancel()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        token = UUID().uuidString
        do {
            let listener = try NWListener(using: .tcp, on: 0)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        self.writeControlFile(port: port)
                        OverlayLog.write("workspace control listening on \(port)")
                    }
                case .failed(let error):
                    OverlayLog.write("workspace control failed: \(error.localizedDescription)")
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            OverlayLog.write("workspace control start failed: \(error.localizedDescription)")
        }
    }

    private func writeControlFile(port: UInt16) {
        let payload: [String: Any] = ["port": Int(port), "token": token]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        OverlayPaths.bootstrap()
        try? FileManager.default.createDirectory(
            at: controlFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: controlFile, options: .atomic)
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64_000) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                OverlayLog.write("workspace control read failed: \(error.localizedDescription)")
                self.finish(connection)
                return
            }
            var next = buffer
            if let data, !data.isEmpty {
                next.append(data)
            }
            if let range = next.range(of: Data([0x0A])) {
                let line = next.subdata(in: next.startIndex..<range.lowerBound)
                self.handleLine(line, on: connection)
                return
            }
            if isComplete {
                self.finish(connection)
                return
            }
            self.receive(connection, buffer: next)
        }
    }

    private func handleLine(_ line: Data, on connection: NWConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            respond(["ok": false, "error": "invalid json"], on: connection)
            return
        }
        let provided = object.string("token") ?? ""
        guard provided == token else {
            respond(["ok": false, "error": "unauthorized"], on: connection)
            return
        }
        let method = object.string("method") ?? ""
        let params = object.dictionary("params") ?? [:]
        guard let handler else {
            respond(["ok": false, "error": WorkspaceError.controlUnavailable.localizedDescription], on: connection)
            return
        }
        Task {
            do {
                let result = try await handler(method, params)
                self.respond(["ok": true, "result": result], on: connection)
            } catch {
                self.respond(["ok": false, "error": error.localizedDescription], on: connection)
            }
        }
    }

    private func respond(_ payload: [String: Any], on connection: NWConnection) {
        queue.async {
            guard JSONSerialization.isValidJSONObject(payload),
                  var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
                self.finish(connection)
                return
            }
            data.append(0x0A)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    OverlayLog.write("workspace control write failed: \(error.localizedDescription)")
                }
                self?.finish(connection)
            })
        }
    }

    private func finish(_ connection: NWConnection) {
        queue.async {
            connection.cancel()
            self.connections.removeValue(forKey: ObjectIdentifier(connection))
        }
    }
}
