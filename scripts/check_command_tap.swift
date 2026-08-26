import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct CommandTapCheck {
    static func main() {
        twoPecksOpen()
        cmdTabDoesNotOpen()
        swallowedTabThenAppSwitch()
        heldCommandIsNotATap()
        slowPairDoesNotOpen()
        bounceDoesNotOpen()
        focusReturnPolicy()
        print("PASS: command tap policy")
    }

    static func twoPecksOpen() {
        var tap = CommandTapMachine()
        tap.commandPressed(at: 1.00, extras: false)
        expect(!tap.commandReleased(at: 1.08, extras: false), "first peck is not a double-tap")
        tap.commandPressed(at: 1.22, extras: false)
        expect(tap.commandReleased(at: 1.30, extras: false), "two short pecks open Bubble")
    }

    static func cmdTabDoesNotOpen() {
        var tap = CommandTapMachine()
        tap.commandPressed(at: 1.00, extras: false)
        tap.otherKey()
        expect(!tap.commandReleased(at: 1.10, extras: false), "Cmd+Tab is a combo")
        tap.commandPressed(at: 1.20, extras: false)
        tap.otherKey()
        expect(!tap.commandReleased(at: 1.30, extras: false), "a second Cmd+Tab still does not open")
    }

    static func swallowedTabThenAppSwitch() {
        var tap = CommandTapMachine()
        tap.commandPressed(at: 1.00, extras: false)
        expect(!tap.commandReleased(at: 1.12, extras: false), "first Cmd+Tab looks like a tap when Tab is swallowed")
        tap.appSwitched()
        tap.commandPressed(at: 1.22, extras: false)
        expect(!tap.commandReleased(at: 1.34, extras: false), "app switch cancels the pending tap")
    }

    static func heldCommandIsNotATap() {
        var tap = CommandTapMachine()
        tap.commandPressed(at: 1.00, extras: false)
        expect(!tap.commandReleased(at: 1.40, extras: false), "a 400ms hold is not a tap")
        tap.commandPressed(at: 1.50, extras: false)
        expect(!tap.commandReleased(at: 1.58, extras: false), "a later peck does not pair with a hold")
    }

    static func slowPairDoesNotOpen() {
        var tap = CommandTapMachine()
        tap.commandPressed(at: 1.00, extras: false)
        expect(!tap.commandReleased(at: 1.08, extras: false), "first peck")
        tap.commandPressed(at: 1.50, extras: false)
        expect(!tap.commandReleased(at: 1.58, extras: false), "too far apart")
    }

    static func bounceDoesNotOpen() {
        var tap = CommandTapMachine()
        tap.commandPressed(at: 1.00, extras: false)
        expect(!tap.commandReleased(at: 1.05, extras: false), "first down")
        tap.commandPressed(at: 1.08, extras: false)
        expect(!tap.commandReleased(at: 1.12, extras: false), "key bounce is too fast")
    }

    static func focusReturnPolicy() {
        expect(
            CommandFocusReturnPolicy.remembers(frontmostPID: 42, bubblePID: 7),
            "opening from another app remembers where focus came from"
        )
        expect(
            !CommandFocusReturnPolicy.remembers(frontmostPID: 7, bubblePID: 7),
            "Bubble must not remember itself as the focus return target"
        )
        expect(
            !CommandFocusReturnPolicy.remembers(frontmostPID: nil, bubblePID: 7),
            "a missing frontmost app is not a return target"
        )
        expect(
            CommandFocusReturnPolicy.preservesExistingTarget(panelVisible: true, requestedTargetPresent: false),
            "a redundant ordinary show must preserve the CMD focus return target"
        )
        expect(
            !CommandFocusReturnPolicy.preservesExistingTarget(panelVisible: false, requestedTargetPresent: false),
            "an ordinary show from hidden starts without a stale focus return target"
        )
        expect(
            !CommandFocusReturnPolicy.preservesExistingTarget(panelVisible: true, requestedTargetPresent: true),
            "an explicit CMD origin replaces any prior target"
        )
    }
}
