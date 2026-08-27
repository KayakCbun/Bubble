import Foundation

struct PiSessionInfo: Equatable {
    var id: String
    var timestamp: String
    var title: String
    var path: String
}

struct PiTreeTurn: Equatable {
    var index: Int
    var id: String
    var text: String
}

struct PiFirstUserInput: Equatable {
    var text: String
    var imageCount: Int
}

enum PiSessions {
    static func directory(for cwd: URL = OverlayPaths.workspace) -> URL {
        let slug = String(cwd.path.drop(while: { $0 == "/" })).replacingOccurrences(of: "/", with: "-")
        return OverlayPaths.piAgent
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("--\(slug)--", isDirectory: true)
    }

    static func list(cwd: URL = OverlayPaths.workspace) -> [PiSessionInfo] {
        let folder = directory(for: cwd)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { $0.hasSuffix(".jsonl") }
            .compactMap { name -> PiSessionInfo? in
                let url = folder.appendingPathComponent(name)
                return summary(from: url)
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    static func currentId() -> String? {
        (try? String(contentsOf: OverlayPaths.sessionIdFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func userTurns(sessionId: String? = nil, cwd: URL = OverlayPaths.workspace) -> [PiTreeTurn] {
        guard let file = file(for: sessionId, cwd: cwd) else { return [] }
        var turns: [PiTreeTurn] = []
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let object = parseLine(String(line)) else { continue }
            guard object.string("type") == "message" else { continue }
            let message = object.dictionary("message") ?? [:]
            guard message.string("role") == "user" else { continue }
            let text = firstText(message["content"])
            let clipped = clip(text.replacingOccurrences(of: "\n", with: " "), 72)
            guard !clipped.isEmpty else { continue }
            turns.append(PiTreeTurn(index: turns.count + 1, id: object.string("id") ?? "", text: clipped))
        }
        return turns
    }

    static func firstUserInput(sessionId: String, cwd: URL = OverlayPaths.workspace) -> PiFirstUserInput? {
        guard let file = exactFile(for: sessionId, cwd: cwd) else { return nil }
        return firstUserInput(file)
    }

    static func conversationTree(sessionId: String, cwd: URL) -> ConversationTreeSnapshot? {
        guard let file = exactFile(for: sessionId, cwd: cwd),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return ConversationTreeSnapshot(jsonl: text)
    }

    static func treeHelp(sessionId: String? = nil) -> String {
        let turns = userTurns(sessionId: sessionId)
        if turns.isEmpty {
            return "No user turns in this Pi session yet.\n/tree shows branch points after the first prompt."
        }
        var lines = ["Session tree (user turns)"]
        for turn in turns.suffix(30) {
            lines.append("\(turn.index). \(turn.text)")
        }
        lines.append("")
        lines.append("Choose a turn to edit it into a new in-session branch.")
        return lines.joined(separator: "\n")
    }

    static func resumeHelp(sessions: [PiSessionInfo], current: String?) -> String {
        if sessions.isEmpty {
            return "No saved Bubble sessions yet. New chats are stored under ~/.pi/agent/sessions."
        }
        var lines = ["Resume a previous Bubble session"]
        for session in sessions.prefix(12) {
            let mark = session.id == current ? "  (current)" : ""
            lines.append("/resume \(session.id)\(mark)")
            lines.append("  \(session.timestamp)  \(session.title)")
        }
        lines.append("")
        lines.append("Or type /resume and pick from the list.")
        return lines.joined(separator: "\n")
    }

    private static func file(for sessionId: String?, cwd: URL) -> URL? {
        let folder = directory(for: cwd)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let wanted = sessionId ?? currentId()
        if let wanted, let match = names.first(where: { $0.contains(wanted) && $0.hasSuffix(".jsonl") }) {
            return folder.appendingPathComponent(match)
        }
        return list(cwd: cwd).first.map { URL(fileURLWithPath: $0.path) }
    }

    private static func exactFile(for sessionId: String, cwd: URL) -> URL? {
        let folder = directory(for: cwd)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard let match = names.first(where: {
            $0.contains(sessionId) && $0.hasSuffix(".jsonl")
        }) else { return nil }
        return folder.appendingPathComponent(match)
    }

    private static func summary(from url: URL) -> PiSessionInfo? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let split = name.firstIndex(of: "_") else { return nil }
        let stamp = String(name[..<split])
        let id = String(name[name.index(after: split)...])
        let title = firstUserText(url) ?? "Untitled session"
        return PiSessionInfo(id: id, timestamp: prettyTimestamp(stamp), title: title, path: url.path)
    }

    private static func firstUserText(_ url: URL) -> String? {
        guard let input = firstUserInput(url) else { return nil }
        let fallback = input.imageCount == 1 ? "Image" : "\(input.imageCount) images"
        let value = input.text.isEmpty ? fallback : input.text
        let clipped = clip(value.replacingOccurrences(of: "\n", with: " "), 56)
        return clipped.isEmpty ? nil : clipped
    }

    private static func firstUserInput(_ url: URL) -> PiFirstUserInput? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(80) {
            guard let object = parseLine(String(line)) else { continue }
            guard object.string("type") == "message" else { continue }
            let message = object.dictionary("message") ?? [:]
            guard message.string("role") == "user" else { continue }
            let value = ConversationTreeSnapshot.displayUserText(firstText(message["content"]))
            let imageCount = (message["content"] as? [Any])?.reduce(into: 0) { count, block in
                if JSONValue.object(block)?.string("type") == "image" { count += 1 }
            } ?? 0
            if !value.isEmpty || imageCount > 0 {
                return PiFirstUserInput(text: value, imageCount: imageCount)
            }
        }
        return nil
    }

    private static func firstText(_ content: Any?) -> String {
        if let string = content as? String { return string }
        if let blocks = content as? [Any] {
            for block in blocks {
                if let text = JSONValue.object(block)?.string("text"), !text.isEmpty {
                    return text
                }
            }
        }
        return ""
    }

    private static func parseLine(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func clip(_ text: String, _ maxChars: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars, maxChars > 1 else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxChars - 1)
        return String(trimmed[..<end]).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func prettyTimestamp(_ raw: String) -> String {
        // 2026-08-21T02-53-26-178Z
        if raw.count >= 16 {
            let date = String(raw.prefix(10))
            let hour = String(raw.dropFirst(11).prefix(2))
            let minute = String(raw.dropFirst(14).prefix(2))
            return "\(date) \(hour):\(minute)"
        }
        return raw
    }
}
