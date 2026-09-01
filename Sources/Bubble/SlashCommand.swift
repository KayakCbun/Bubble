import Foundation

struct SlashCommand: Identifiable, Equatable {
    var name: String
    var description: String
    var hint: String? = nil
    var local: Bool = false

    var id: String { name }
    var token: String { "/\(name)" }

    static func parse(_ value: Any) -> SlashCommand? {
        guard let object = JSONValue.object(value),
              let name = object.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        let hint = object.dictionary("input")?.string("hint")
        return SlashCommand(
            name: name.hasPrefix("/") ? String(name.dropFirst()) : name,
            description: object.string("description") ?? "",
            hint: hint,
            local: false
        )
    }

    static func isComposing(_ draft: String) -> Bool {
        if case .slash = PromptPalette.activeToken(in: draft)?.trigger {
            return true
        }
        return false
    }

    static func token(in draft: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let name = body.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return name.lowercased()
    }

    static func arguments(in draft: String) -> String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = trimmed.firstIndex(where: \.isWhitespace) else { return "" }
        return String(trimmed[trimmed.index(after: space)...]).trimmingCharacters(in: .whitespaces)
    }

    static func matches(_ commands: [SlashCommand], query: String) -> [SlashCommand] {
        let q = query.lowercased()
        if q.isEmpty { return commands }
        let prefixed = commands.filter { $0.name.lowercased().hasPrefix(q) }
        if !prefixed.isEmpty { return prefixed }
        return commands.filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }

    static let builtIn: [SlashCommand] = [
        .init(name: "help", description: "Show slash command help", local: true),
        .init(name: "setup", description: "Install Pi and pi-acp into ~/.bubble/runtime", local: true),
        .init(name: "install", description: "Install Pi and pi-acp into ~/.bubble/runtime", local: true),
        .init(name: "login", description: "Sign in a Pi provider (API key or Terminal)", hint: "provider [api-key]", local: true),
        .init(name: "logout", description: "Remove a saved Pi provider", hint: "provider", local: true),
        .init(name: "resume", description: "Resume a previous Bubble session", hint: "session-id", local: true),
        .init(name: "tree", description: "Edit an earlier message and branch from it", hint: "message", local: true),
        .init(name: "reload", description: "Reconnect Pi and refresh commands", local: true),
        .init(name: "model", description: "Set Bubble's model (does not change Pi TUI)", hint: "provider/id", local: true),
        .init(name: "thinking", description: "Set Bubble's thinking level", hint: "off|minimal|low|medium|high|xhigh", local: true),
        .init(name: "agents", description: "Edit Bubble's AGENTS.md", local: true),
        .init(name: "open", description: "Open an installed Mac app", hint: "Safari", local: true),
        .init(name: "mounts", description: "Browse folders; click to open, icon to mount", hint: "folder", local: true),
        .init(name: "clipboard", description: "Attach the live clipboard and send", local: true),
        .init(name: "clear", description: "Start a fresh session", local: true),
        .init(name: "new", description: "Start a fresh session", local: true),
        .init(name: "side", description: "Open a parallel side session", local: true),
        .init(name: "close", description: "Close this side session, or hide Bubble from the main session", local: true),
        .init(name: "loop", description: "Create a session-bound repeating task", hint: "5m 检查部署", local: true),
        .init(name: "compact", description: "Compact older conversation turns now", hint: "instructions", local: false),
        .init(name: "autocompact", description: "Toggle automatic compaction", hint: "on|off|toggle", local: false),
        .init(name: "session", description: "Show session stats", local: false),
        .init(name: "name", description: "Set session display name", hint: "name", local: false),
        .init(name: "export", description: "Export the current session to HTML", local: false),
        .init(name: "steering", description: "Get or set steering mode", local: false),
        .init(name: "follow-up", description: "Get or set follow-up mode", local: false),
        .init(name: "copy", description: "Copy the latest assistant response", local: true),
        .init(name: "quit", description: "Hide Bubble", local: true),
        .init(name: "exit", description: "Hide Bubble", local: true),
    ]

    static func helpText(from commands: [SlashCommand], skills: [PiSkill] = []) -> String {
        var lines = commands.map { command in
            let hint = command.hint.map { " \($0)" } ?? ""
            return "/\(command.name)\(hint) — \(command.description)"
        }
        if !skills.isEmpty {
            lines.append("")
            lines.append("Skills  ($ or /skill:name)")
            lines.append(contentsOf: skills.map { "$\($0.name) — \($0.description)" })
        }
        return """
        Composer
        Type / for commands and prompt templates.
        Type @ to mention a workspace file. @clipboard attaches the live clipboard.
        Type /open to search and launch installed Mac apps.
        Type /mounts to mount or unmount a local folder.
        Type /setup to install Pi and pi-acp into ~/.bubble/runtime.
        Type /login to sign in a provider. Type /resume to switch sessions.
        Type /close to close the current side session. In the main session it hides Bubble.
        Type $ or /skill:name to pick a skill.

        Slash commands
        \(lines.joined(separator: "\n"))
        """
    }
}
