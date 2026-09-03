import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("agentic UI extension check failed: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum AgenticUIExtensionCheck {
    static func main() {
        let guide = BubbleConfig.agenticUISection
        require(guide.contains("The user does not need to ask for a chart"), "the agent is told to choose native UI autonomously")
        require(guide.contains("Do not use it for decoration"), "the autonomy rule includes a restraint boundary")

        let source = BubbleConfig.workspaceExtensionSource
        require(source.contains(#"name: "bubble_render""#), "the Bubble agent registers the native render tool")
        require(source.contains(#"await call("bubble_render""#), "the tool submits the validated spec to Bubble")
        require(source.contains(#"pi.appendEntry("bubble_agentic_ui", params)"#), "successful renders persist in the Pi session")
        require(source.contains("Do not wait for the user to say chart"), "the tool prompt makes selection automatic")
        require(source.contains(#"Type.Literal("BarChart")"#), "the model sees the native chart catalog")

        let call = source.range(of: #"await call("bubble_render""#)?.lowerBound
        let persist = source.range(of: #"pi.appendEntry("bubble_agentic_ui", params)"#)?.lowerBound
        require(call != nil && persist != nil && call! < persist!, "invalid specs are not persisted before Bubble accepts them")

        if let output = ProcessInfo.processInfo.environment["BUBBLE_EXTENSION_OUTPUT"], !output.isEmpty {
            try! source.write(toFile: output, atomically: true, encoding: .utf8)
        }

        print("PASS: autonomous native UI tool registration and persistence contract")
    }
}
