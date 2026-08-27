import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct EscapeDispatchCheck {
    static func main() throws {
        let controller = try String(
            contentsOfFile: "Sources/Bubble/OverlayController.swift",
            encoding: .utf8
        )
        let view = try String(
            contentsOfFile: "Sources/Bubble/OverlayView.swift",
            encoding: .utf8
        )

        require(
            controller.components(separatedBy: "event.keyCode == 53").count - 1 == 1,
            "the overlay controller owns exactly one Escape event entry point"
        )
        require(
            !view.contains(".onKeyPress(.escape)"),
            "SwiftUI must not redispatch Escape after AppKit has cancelled a busy turn"
        )
        require(
            controller.contains("let action = OverlayEscapePolicy.action("),
            "the sole Escape entry point must use the executable action policy"
        )

        print("PASS: Escape dispatch policy")
    }
}
