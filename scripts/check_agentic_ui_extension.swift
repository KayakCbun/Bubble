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
        require(source.contains(#"pi.appendEntry("bubble_agentic_ui", request)"#), "successful renders persist in the Pi session")
        require(source.contains("Do not wait for the user to say chart"), "the tool prompt makes selection automatic")
        require(source.contains(#"Type.Literal("BarChart")"#), "the model sees the native chart catalog")
        require(source.contains(#"Type.Literal("AreaChart")"#), "the model sees the native area chart")
        require(source.contains(#"Type.Literal("ScatterChart")"#), "the model sees the native scatter chart")
        require(source.contains("const nativeScatterPoint"), "scatter coordinates have a typed model-facing schema")
        require(source.contains("filterColumn: Type.Optional"), "the model can link a table to chart-label filtering")
        require(source.contains("filterGroup: Type.Optional"), "the model can scope linked charts and tables without label collisions")
        require(source.contains("same filterGroup"), "the agent is told to group only related interactive components")
        require(source.contains("Charts are clickable by default"), "the agent knows native chart interaction requires no explicit wiring")
        require(source.contains("AreaChart for magnitude over time"), "the agent receives an autonomous chart-selection rule")
        require(source.contains("ScatterChart for correlation"), "the agent receives an autonomous correlation rule")
        require(source.contains("const nativeElement = Type.Union"), "the model-facing catalog is discriminated by component")
        require(source.contains("additionalProperties: false"), "component props reject unknown fields before host dispatch")
        require(!source.contains("props: Type.Record(Type.String(), Type.Unknown())"), "the model-facing catalog does not advertise arbitrary props")
        require(source.contains("blockID: _id"), "tool retries carry a stable native block identity")
        require(source.contains("hasPersistedNativeBlock(ctx, _id)"), "a retried tool call cannot duplicate its authoritative Pi session entry")
        require(source.contains("ctx.sessionManager.getEntries()"), "retry deduplication survives extension restarts")

        let call = source.range(of: #"await call("bubble_render""#)?.lowerBound
        let persist = source.range(of: #"pi.appendEntry("bubble_agentic_ui", request)"#)?.lowerBound
        require(call != nil && persist != nil && call! < persist!, "invalid specs are not persisted before Bubble accepts them")

        if let output = ProcessInfo.processInfo.environment["BUBBLE_EXTENSION_OUTPUT"], !output.isEmpty {
            try! source.write(toFile: output, atomically: true, encoding: .utf8)
        }

        print("PASS: autonomous native UI tool registration and persistence contract")
    }
}
