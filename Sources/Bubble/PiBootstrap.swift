import AppKit
import Foundation

enum PiBootstrap {
    static let piPackage = BubblePiRuntimePatch.packageSpec
    static let acpPackage = BubblePiAcpPatch.packageSpec

    enum Outcome {
        case alreadyReady
        case needNode(String)
        case installed
    }

    static func install(onLog: @escaping (String) -> Void) throws -> Outcome {
        OverlayPaths.bootstrap()
        try FileManager.default.createDirectory(at: OverlayPaths.runtime, withIntermediateDirectories: true)

        let report = PiSetup.diagnose()
        if !report.nodeSupported {
            let detail: String
            if let version = report.nodeVersion {
                detail = "Node \(version) is too old. Pi needs 22.19.0 or newer."
            } else {
                detail = "Node.js 22.19.0 or newer is required."
            }
            onLog(detail)
            onLog("Opening the Node download page…")
            NSWorkspace.shared.open(PiSetup.nodeDownloadURL)
            return .needNode(detail)
        }

        if report.piInstalled,
           BubblePiRuntimePatch.isApplied(runtime: OverlayPaths.runtime),
           BubblePiAcpPatch.isApplied(runtime: OverlayPaths.runtime) {
            onLog("Pi and Bubble's branch-capable pi-acp are already installed.")
            return .alreadyReady
        }

        guard let npm = OverlayPaths.resolveCommand("npm") else {
            throw RPCError(code: -1, message: "npm not found. Reinstall Node from https://nodejs.org/en/download")
        }

        let packages = [piPackage, acpPackage]

        onLog("Installing \(packages.joined(separator: " and ")) into ~/.bubble/runtime…")
        try run(
            executable: npm,
            arguments: ["install", "--prefix", OverlayPaths.runtime.path, "--omit=dev", "--ignore-scripts"] + packages,
            onLog: onLog
        )
        try BubblePiRuntimePatch.apply(runtime: OverlayPaths.runtime)
        try BubblePiAcpPatch.apply(runtime: OverlayPaths.runtime)

        let pi = BubblePiRuntimePatch.isApplied(runtime: OverlayPaths.runtime)
            ? OverlayPaths.runtimeBin.appendingPathComponent("pi")
            : nil
        let acp = BubblePiAcpPatch.isApplied(runtime: OverlayPaths.runtime)
            ? OverlayPaths.runtimeBin.appendingPathComponent("pi-acp")
            : nil
        if pi == nil {
            throw RPCError(code: -1, message: "npm finished, but `pi` is still missing.")
        }
        if acp == nil {
            throw RPCError(code: -1, message: "npm finished, but `pi-acp` is still missing.")
        }
        onLog("Installed pi at \(pi!.path)")
        return .installed
    }

    private static func run(
        executable: URL,
        arguments: [String],
        onLog: @escaping (String) -> Void
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = OverlayPaths.runtime
        var env = OverlayPaths.processEnvironment()
        env["npm_config_fund"] = "false"
        env["npm_config_update_notifier"] = "false"
        env["npm_config_audit"] = "false"
        env["NPM_CONFIG_PREFIX"] = OverlayPaths.runtime.path
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let handleLog: (FileHandle) -> Void = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    onLog(String(trimmed))
                }
            }
        }
        stdout.fileHandleForReading.readabilityHandler = handleLog
        stderr.fileHandleForReading.readabilityHandler = handleLog

        try process.run()
        process.waitUntilExit()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        handleLog(stdout.fileHandleForReading)
        handleLog(stderr.fileHandleForReading)

        guard process.terminationStatus == 0 else {
            throw RPCError(
                code: -1,
                message: "Install failed (exit \(process.terminationStatus)). See ~/.bubble/overlay.log"
            )
        }
    }
}
