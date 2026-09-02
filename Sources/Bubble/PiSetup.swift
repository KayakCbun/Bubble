import Foundation

struct LoginProvider: Equatable {
    var id: String
    var title: String
    var detail: String
    var oauth: Bool
    var env: String?
}

enum PiSetup {
    static let providers: [LoginProvider] = [
        .init(id: "openai-codex", title: "ChatGPT Codex", detail: "ChatGPT Plus/Pro subscription", oauth: true, env: nil),
        .init(id: "anthropic", title: "Anthropic", detail: "Claude API key or Pro/Max", oauth: true, env: "ANTHROPIC_API_KEY"),
        .init(id: "github-copilot", title: "GitHub Copilot", detail: "Copilot subscription", oauth: true, env: nil),
        .init(id: "xai", title: "xAI", detail: "Grok API key or X subscription", oauth: true, env: "XAI_API_KEY"),
        .init(id: "openai", title: "OpenAI", detail: "OpenAI API key", oauth: false, env: "OPENAI_API_KEY"),
        .init(id: "google", title: "Google Gemini", detail: "Gemini API key", oauth: false, env: "GEMINI_API_KEY"),
        .init(id: "openrouter", title: "OpenRouter", detail: "API key or OAuth", oauth: true, env: "OPENROUTER_API_KEY"),
        .init(id: "deepseek", title: "DeepSeek", detail: "DeepSeek API key", oauth: false, env: "DEEPSEEK_API_KEY"),
        .init(id: "zai", title: "ZAI", detail: "ZAI Coding Plan API key", oauth: false, env: "ZAI_API_KEY"),
        .init(id: "mistral", title: "Mistral", detail: "Mistral API key", oauth: false, env: "MISTRAL_API_KEY"),
        .init(id: "groq", title: "Groq", detail: "Groq API key", oauth: false, env: "GROQ_API_KEY"),
        .init(id: "kimi-coding", title: "Kimi", detail: "Kimi For Coding API key", oauth: false, env: "KIMI_API_KEY"),
        .init(id: "minimax", title: "MiniMax", detail: "MiniMax API key", oauth: false, env: "MINIMAX_API_KEY"),
    ]

    static let minimumNode = (major: 22, minor: 19, patch: 0)
    static let nodeDownloadURL = URL(string: "https://nodejs.org/en/download")!

    struct Report: Equatable {
        var nodeInstalled: Bool
        var nodeVersion: String?
        var nodeSupported: Bool
        var piInstalled: Bool
        var acpInstalled: Bool
        var acpAvailable: Bool
        var credentialProviders: [String]

        var hasCredentials: Bool { !credentialProviders.isEmpty }
        var ready: Bool { piInstalled && acpAvailable && hasCredentials }
        var needsRuntimeInstall: Bool { !piInstalled || !acpInstalled }
        var canInstallRuntime: Bool { nodeSupported }
    }

    static func diagnose() -> Report {
        let node = OverlayPaths.resolveCommand("node")
        let version = node.flatMap { readNodeVersion($0) }
        let branchRuntime = BubblePiRuntimePatch.ensureApplied(runtime: OverlayPaths.runtime)
        let branchAdapter = branchRuntime && BubblePiAcpPatch.ensureApplied(runtime: OverlayPaths.runtime)
        return Report(
            nodeInstalled: node != nil,
            nodeVersion: version,
            nodeSupported: version.map(nodeVersionAtLeast) ?? false,
            piInstalled: branchRuntime,
            acpInstalled: branchAdapter,
            acpAvailable: branchAdapter && OverlayPaths.resolveAgentLaunch() != nil,
            credentialProviders: credentialProviders()
        )
    }

    static func parseNodeVersion(_ raw: String) -> (Int, Int, Int)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let parts = body.split(separator: ".").prefix(3).compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1], parts.count > 2 ? parts[2] : 0)
    }

    static func nodeVersionAtLeast(_ raw: String) -> Bool {
        guard let version = parseNodeVersion(raw) else { return false }
        let min = minimumNode
        if version.0 != min.major { return version.0 > min.major }
        if version.1 != min.minor { return version.1 > min.minor }
        return version.2 >= min.patch
    }

    private static func readNodeVersion(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = ["-v"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    static func credentialProviders() -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        for key in authFile().keys.sorted() {
            if seen.insert(key).inserted { found.append(key) }
        }
        for provider in providers {
            guard let env = provider.env, let value = ProcessInfo.processInfo.environment[env], !value.isEmpty else {
                continue
            }
            if seen.insert(provider.id).inserted {
                found.append(provider.id)
            }
        }
        return found
    }

    static func provider(id: String) -> LoginProvider? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return providers.first { $0.id == key || $0.title.lowercased() == key }
            ?? providers.first { $0.id.contains(key) || $0.title.lowercased().contains(key) }
    }

    static func setupCard(_ report: Report, error: String? = nil) -> String {
        var lines = ["Set up Bubble"]
        if let error, !error.isEmpty {
            lines.append(error)
            lines.append("")
        }
        lines.append("Bubble talks to Pi. A first-time Mac needs Node 22.19+, Pi, the ACP adapter, and one signed-in provider.")
        lines.append("")
        if report.nodeSupported {
            let version = report.nodeVersion.map { " (\($0))" } ?? ""
            lines.append("1. Node — installed\(version)")
        } else if report.nodeInstalled {
            lines.append("1. Node — \(report.nodeVersion ?? "too old"). Pi needs 22.19.0 or newer.")
            lines.append("   Type /setup to open the Node download page.")
        } else {
            lines.append("1. Node — not found. Install the official macOS package (22.19+).")
            lines.append("   Type /setup to open https://nodejs.org/en/download")
        }
        lines.append(report.piInstalled ? "2. Pi — installed" : "2. Pi — not found")
        lines.append(report.acpInstalled || report.acpAvailable ? "3. pi-acp — available" : "3. pi-acp — not found")
        if report.needsRuntimeInstall, report.canInstallRuntime {
            lines.append("")
            lines.append("Type /setup to install Pi and pi-acp into ~/.bubble/runtime, then Bubble reconnects.")
        } else if !report.nodeSupported {
            lines.append("")
            lines.append("Install Node first, then type /setup.")
        }
        if report.hasCredentials {
            lines.append("4. Provider — \(report.credentialProviders.joined(separator: ", "))")
        } else {
            lines.append("4. Sign in to a provider")
            lines.append("   Type /login and pick a provider.")
            lines.append("   API key: /login xai sk-...")
            lines.append("   Subscription: /login opens Pi in Terminal, then type /login there.")
        }
        lines.append("5. Pick a model with /model")
        lines.append("")
        lines.append("After installing or signing in, type /reload if Bubble does not reconnect on its own.")
        return lines.joined(separator: "\n")
    }

    static func loginHelp() -> String {
        let report = diagnose()
        var lines = [
            "Sign in so Bubble can call a model.",
            "",
            "API key:",
            "/login xai sk-...",
            "",
            "Subscription (ChatGPT, Claude Pro/Max, Copilot, Grok):",
            "/login openai-codex",
            "That opens Terminal. In Pi, type /login and finish the browser flow.",
            "",
            "Providers",
        ]
        for provider in providers {
            let marked = report.credentialProviders.contains(provider.id) ? "  (signed in)" : ""
            lines.append("/login \(provider.id) — \(provider.detail)\(marked)")
        }
        return lines.joined(separator: "\n")
    }

    static func saveAPIKey(provider: String, key: String) throws {
        let id = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw RPCError(code: -10, message: "Provider is empty.") }
        guard token.count >= 8 else { throw RPCError(code: -10, message: "That API key looks too short.") }
        OverlayPaths.bootstrap()
        try FileManager.default.createDirectory(at: OverlayPaths.piAgent, withIntermediateDirectories: true)
        var json = authFile()
        json[id] = ["type": "api_key", "key": token]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: authURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    }

    static func removeProvider(_ provider: String) throws -> Bool {
        let id = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var json = authFile()
        guard json.removeValue(forKey: id) != nil else { return false }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: authURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
        return true
    }

    static func maskedKey(_ key: String) -> String {
        let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.count <= 8 { return "••••" }
        return token.prefix(4) + "…" + token.suffix(4)
    }

    static func openPiTerminal() -> String? {
        let cwd = OverlayPaths.workspace.path
        let command = "cd \(shellEscape(cwd)) && echo 'In Pi, type /login then pick a provider. Close this window when done.' && exec pi"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "tell application \"Terminal\" to activate",
            "-e",
            "tell application \"Terminal\" to do script \(appleQuote(command))",
        ]
        do {
            try process.run()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static var authURL: URL {
        OverlayPaths.piAgent.appendingPathComponent("auth.json")
    }

    private static func authFile() -> [String: Any] {
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
