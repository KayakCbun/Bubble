import Foundation

/// Double-tap Command, without treating Cmd+Tab / held shortcuts as taps.
enum CommandTapPolicy {
    static let minInterval: TimeInterval = 0.12
    static let maxInterval: TimeInterval = 0.32
    static let maxHold: TimeInterval = 0.22
}

enum CommandFocusReturnPolicy {
    static func remembers(frontmostPID: Int32?, bubblePID: Int32) -> Bool {
        guard let frontmostPID else { return false }
        return frontmostPID != bubblePID
    }

    static func preservesExistingTarget(panelVisible: Bool, requestedTargetPresent: Bool) -> Bool {
        panelVisible && !requestedTargetPresent
    }
}

struct CommandTapMachine {
    private var commandDown = false
    private var combo = false
    private var downAt: TimeInterval = 0
    private var lastTap: TimeInterval = 0

    mutating func commandPressed(at time: TimeInterval, extras: Bool) {
        commandDown = true
        combo = extras
        downAt = time
    }

    /// Returns true when this release completes a double-tap.
    mutating func commandReleased(at time: TimeInterval, extras: Bool) -> Bool {
        guard commandDown else { return false }
        commandDown = false
        let wasCombo = combo || extras
        combo = false
        guard !wasCombo else { return false }
        if time - downAt > CommandTapPolicy.maxHold {
            lastTap = 0
            return false
        }
        let delta = time - lastTap
        lastTap = time
        if delta > CommandTapPolicy.minInterval && delta < CommandTapPolicy.maxInterval {
            lastTap = 0
            return true
        }
        return false
    }

    mutating func otherKey() {
        combo = true
    }

    mutating func appSwitched() {
        combo = true
        lastTap = 0
    }
}
