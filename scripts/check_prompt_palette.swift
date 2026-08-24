import Foundation

private var failures: [String] = []

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}

@main
private enum PromptPaletteCheck {
    static func main() {
        expect(!PromptTriggerPolicy.hasActiveTrigger(in: "ordinary typing"), "ordinary prose must bypass palette work")
        expect(PromptTriggerPolicy.hasActiveTrigger(in: "/model openai"), "slash command arguments keep the palette active")
        expect(PromptTriggerPolicy.hasActiveTrigger(in: "then /model"), "inline slash tokens keep the palette active")
        expect(PromptTriggerPolicy.hasActiveTrigger(in: "attach @file"), "mentions keep the palette active")
        expect(PromptTriggerPolicy.hasActiveTrigger(in: "use $skill"), "skill tokens keep the palette active")
        if !failures.isEmpty {
            failures.forEach { FileHandle.standardError.write(Data("FAIL: \($0)\n".utf8)) }
            exit(1)
        }
        print("PASS: prompt palette trigger")
    }
}
