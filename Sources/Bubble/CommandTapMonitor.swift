import AppKit
import ApplicationServices

final class CommandTapMonitor {
    var onDoubleTap: (() -> Void)?

    private var globalFlags: Any?
    private var localFlags: Any?
    private var globalKeys: Any?
    private var localKeys: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var machine = CommandTapMachine()

    func start() {
        stop()
        globalFlags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
        }
        localFlags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
            return event
        }
        globalKeys = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] _ in
            self?.machine.otherKey()
        }
        localKeys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            if event.keyCode != 55 && event.keyCode != 54 {
                self?.machine.otherKey()
            }
            return event
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.machine.appSwitched()
        }
    }

    func stop() {
        if let globalFlags { NSEvent.removeMonitor(globalFlags) }
        if let localFlags { NSEvent.removeMonitor(localFlags) }
        if let globalKeys { NSEvent.removeMonitor(globalKeys) }
        if let localKeys { NSEvent.removeMonitor(localKeys) }
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        globalFlags = nil
        localFlags = nil
        globalKeys = nil
        localKeys = nil
        workspaceObserver = nil
        machine = CommandTapMachine()
    }

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func promptForTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func handleFlags(_ event: NSEvent) {
        let isCommandKey = event.keyCode == 55 || event.keyCode == 54
        guard isCommandKey else {
            machine.otherKey()
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let commandHeld = flags.contains(.command)
        let extras = !flags.subtracting([.command, .capsLock]).isEmpty
        let now = ProcessInfo.processInfo.systemUptime

        if commandHeld {
            machine.commandPressed(at: now, extras: extras)
            return
        }

        if machine.commandReleased(at: now, extras: extras) {
            DispatchQueue.main.async { [weak self] in
                self?.onDoubleTap?()
            }
        }
    }
}
