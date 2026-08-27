import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct BubbleNativeActionCheck {
    static func main() throws {
        expect(
            BubbleNativeAction.slashCommand(action: "create_side_session", argument: nil) == "/side",
            "natural-language side requests reuse the local side-session command"
        )
        expect(
            BubbleNativeAction.slashCommand(action: "close_session", argument: nil) == "/close",
            "natural-language close requests reuse the non-pointer close path"
        )
        expect(
            BubbleNativeAction.slashCommand(action: "open_app", argument: "  Safari  ") == "/open Safari",
            "Bubble actions preserve a trimmed command argument"
        )
        expect(
            BubbleNativeAction.slashCommand(action: "hide_window", argument: nil) == "/quit",
            "AI-native hide requests reuse Bubble's existing window action"
        )
        expect(
            BubbleNativeAction.slashCommand(action: "unknown", argument: nil) == nil,
            "the model cannot invoke commands outside Bubble's advertised action set"
        )
        let config = try String(
            contentsOfFile: "Sources/Bubble/BubbleConfig.swift",
            encoding: .utf8
        )
        expect(config.contains(#"name: "bubble_action""#),
               "the Pi extension advertises Bubble's native action tool")
        expect(config.contains("Use this only for an explicit user request"),
               "the native action tool is gated on explicit user intent")

        let control = try String(
            contentsOfFile: "Sources/Bubble/BubbleControl.swift",
            encoding: .utf8
        )
        expect(control.contains("afterResponse?.run()"),
               "self-destructive actions run only after their control response is sent")

        let tabs = try String(
            contentsOfFile: "Sources/Bubble/SessionTabsView.swift",
            encoding: .utf8
        )
        expect(!tabs.contains("requestClose"),
               "session tabs expose no pointer close action")
        expect(!tabs.contains("SessionTabCloseConfirmation"),
               "session tabs expose no hover close confirmation")

        print("PASS: Bubble native actions")
    }
}
