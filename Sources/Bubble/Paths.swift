import Foundation

struct AgentLaunch {
    var executable: URL
    var arguments: [String]
}

enum OverlayPaths {
    static let bundleId = "local.bubble"
    static let appName = "Bubble"

    static var home: URL {
        if let override = ProcessInfo.processInfo.environment["BUBBLE_HOME_OVERRIDE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    static var root: URL {
        home.appendingPathComponent(".bubble", isDirectory: true)
    }

    static var workspace: URL {
        root.appendingPathComponent("workspace", isDirectory: true)
    }

    static var configFile: URL {
        root.appendingPathComponent("config.json")
    }

    static var recordFile: URL {
        root.appendingPathComponent("record.json")
    }

    static var mountsFile: URL {
        root.appendingPathComponent("mounts.json")
    }

    static var controlFile: URL {
        root.appendingPathComponent("control.json")
    }

    static var controlsDirectory: URL {
        root.appendingPathComponent("controls", isDirectory: true)
    }

    static func sideControlFile(runtimeID: UUID) -> URL {
        controlsDirectory.appendingPathComponent("\(runtimeID.uuidString).json")
    }

    static var steeringDirectory: URL {
        root.appendingPathComponent("steering", isDirectory: true)
    }

    static func steeringControlFile(sessionId: String) -> URL {
        steeringDirectory.appendingPathComponent("\(sessionId).json")
    }

    static var agentsFile: URL {
        root.appendingPathComponent("AGENTS.md")
    }

    static var workspaceAgentsFile: URL {
        workspace.appendingPathComponent("AGENTS.md")
    }

    static var workspaceExtensionFile: URL {
        workspace
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent("bubble-workspace.ts")
    }

    static var workspaceSkillsDirectory: URL {
        workspace
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    static var piAgent: URL {
        home.appendingPathComponent(".pi/agent", isDirectory: true)
    }

    static var userAgentsSkills: URL {
        home.appendingPathComponent(".agents/skills", isDirectory: true)
    }

    static var sessionIdFile: URL {
        root.appendingPathComponent("session-id")
    }

    static var sessionTabsFile: URL {
        root.appendingPathComponent("session-tabs.json")
    }

    static var loopsFile: URL {
        root.appendingPathComponent("loops.json")
    }

    static var transcriptFile: URL {
        root.appendingPathComponent("transcript.json")
    }

    static var logFile: URL {
        root.appendingPathComponent("overlay.log")
    }

    static var acpLogFile: URL {
        root.appendingPathComponent("acp.log")
    }

    static var imagesDirectory: URL {
        root.appendingPathComponent("images", isDirectory: true)
    }

    static var runtime: URL {
        root.appendingPathComponent("runtime", isDirectory: true)
    }

    static var runtimeBin: URL {
        runtime.appendingPathComponent("node_modules/.bin", isDirectory: true)
    }

    static var bubbleBin: URL {
        root.appendingPathComponent("bin", isDirectory: true)
    }

    static var avatarFile: URL {
        root.appendingPathComponent("avatar")
    }

    static func bootstrap() {
        let fm = FileManager.default
        try? fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        try? fm.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: runtime, withIntermediateDirectories: true)
        try? fm.createDirectory(at: steeringDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: controlsDirectory, withIntermediateDirectories: true)
        BubbleSlotCatalog.ensureAll(in: root)
        BubbleConfig.ensureAgentsFile()
        BubbleConfig.ensureWorkspaceExtension()
        BubbleConfig.ensureWorkspaceTrust()
        BubbleConfig.ensureUnslopSkill()
    }

    static func resolveAgentLaunch() -> AgentLaunch? {
        if let piAcp = resolveCommand("pi-acp") {
            return AgentLaunch(executable: piAcp, arguments: [])
        }
        if let npx = resolveCommand("npx") {
            return AgentLaunch(executable: npx, arguments: ["-y", "pi-acp"])
        }
        return nil
    }

    static func which(_ name: String) -> URL? {
        for directory in searchPathDirectories() {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    static func resolveCommand(_ name: String) -> URL? {
        which(name) ?? loginShellWhich(name)
    }

    static func loginShellWhich(_ name: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]
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
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func processEnvironment(controlFile: URL? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = searchPathDirectories().map(\.path)
        let existing = env["PATH"] ?? ""
        env["PATH"] = (extra + [existing]).joined(separator: ":")
        env["HOME"] = home.path
        if let controlFile {
            env["BUBBLE_CONTROL_FILE"] = controlFile.path
        }
        return env
    }

    private static func searchPathDirectories() -> [URL] {
        var dirs = [
            runtimeBin,
            bubbleBin,
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent(".nvm/current/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/opt/homebrew/opt/node@22/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/usr/bin"),
            URL(fileURLWithPath: "/bin"),
        ]
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        dirs.append(contentsOf: pathDirs)
        var seen = Set<String>()
        return dirs.filter { seen.insert($0.path).inserted }
    }
}

enum OverlayLog {
    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
            OverlayPaths.bootstrap()
            if !FileManager.default.fileExists(atPath: OverlayPaths.logFile.path) {
                FileManager.default.createFile(atPath: OverlayPaths.logFile.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: OverlayPaths.logFile) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }
}
