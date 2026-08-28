import AppKit
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct ComposerEditorCheck {
    static func main() {
        _ = NSApplication.shared

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: panel.contentView!.bounds)
        panel.contentView = root

        let search = NSTextField(frame: NSRect(x: 48, y: 110, width: 400, height: 28))
        search.placeholderString = "Search apps"
        let composer = NSTextField(frame: NSRect(x: 48, y: 20, width: 400, height: 28))
        composer.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        let probe = NSView(frame: composer.frame)
        root.addSubview(search)
        root.addSubview(composer)
        root.addSubview(probe)

        let matched = ComposerEditorLocator.matchingTextField(in: root, alignedWith: probe)
        expect(matched === composer, "the probe must identify the aligned composer, not a palette search field")
        ComposerEditorLocator.markComposerField(composer)
        expect(
            composer.identifier?.rawValue == ComposerEditorIdentity.viewIdentifier,
            "the native composer field must retain a stable identity"
        )

        panel.makeKeyAndOrderFront(nil)
        expect(panel.makeFirstResponder(composer), "the composer must become first responder")
        guard let editor = ComposerEditorLocator.ensureFieldEditor(
            in: panel,
            composerField: composer
        ) else {
            FileHandle.standardError.write(Data("FAIL: the busy route must resolve the live field editor\n".utf8))
            exit(1)
        }
        expect(editor.delegate as? NSTextField === composer, "the resolved editor must belong to the composer")
        type("x", keyCode: 7, into: editor)
        expect(editor.string == "x", "a working composer must accept a real key event")

        let staleHeavyFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        editor.font = staleHeavyFont
        editor.typingAttributes[.font] = staleHeavyFont
        guard let normalizedEditor = ComposerEditorLocator.ensureFieldEditor(
            in: panel,
            composerField: composer
        ) else {
            FileHandle.standardError.write(Data("FAIL: the composer editor must remain available while normalizing typography\n".utf8))
            exit(1)
        }
        expect(
            normalizedEditor.font?.fontName == composer.font?.fontName,
            "a reused field editor must inherit the composer's regular font weight"
        )
        expect(
            (normalizedEditor.typingAttributes[.font] as? NSFont)?.fontName == composer.font?.fontName,
            "new composer input must use the same regular font weight as conversation text"
        )

        expect(panel.makeFirstResponder(search), "the palette search field must become first responder")
        expect(
            ComposerEditorLocator.ensureFieldEditor(in: panel, composerField: composer) == nil,
            "busy routing must not steal an explicitly focused palette search field"
        )

        let scrollToEnd = NSButton(title: "Scroll to end", target: nil, action: nil)
        root.addSubview(scrollToEnd)
        expect(panel.makeFirstResponder(scrollToEnd), "scroll to end must be able to receive its click focus")
        guard let editorAfterScroll = ComposerEditorLocator.restoreComposerFocus(
            in: panel,
            root: root
        ) else {
            FileHandle.standardError.write(Data("FAIL: scroll to end must restore the composer field editor\n".utf8))
            exit(1)
        }
        editorAfterScroll.string = ""
        type("s", keyCode: 1, into: editorAfterScroll)
        expect(
            editorAfterScroll.string == "s",
            "the composer must accept input immediately after scroll to end"
        )

        expect(panel.makeFirstResponder(composer), "the composer must regain focus before abort")
        let staleEditor = panel.firstResponder
        ComposerEditorLocator.releaseFieldEditor(in: panel)
        expect(panel.firstResponder !== staleEditor, "abort must detach the stale field editor")

        // SwiftUI can leave the identified field in the hierarchy for one
        // render pass while installing its replacement at the same geometry.
        // The live replacement owns the field editor and must win over the
        // stale identified field.
        let replacement = NSTextField(frame: composer.frame)
        root.addSubview(replacement)
        expect(panel.makeFirstResponder(replacement), "the replacement composer must become first responder")
        expect(
            ComposerEditorLocator.composerField(in: root) === replacement,
            "the live replacement must win while stale and new composer fields coexist"
        )
        guard let restoredEditor = ComposerEditorLocator.ensureFieldEditor(
            in: panel,
            composerField: ComposerEditorLocator.composerField(in: root)
        ) else {
            FileHandle.standardError.write(Data("FAIL: abort must restore a live composer editor\n".utf8))
            exit(1)
        }
        restoredEditor.string = ""
        type("y", keyCode: 16, into: restoredEditor)
        expect(restoredEditor.string == "y", "the composer must accept input after abort")

        panel.orderOut(nil)
        print("PASS: composer native editor routing")
    }

    private static func type(_ text: String, keyCode: UInt16, into editor: NSTextView) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: editor.window?.windowNumber ?? 0,
            context: nil,
            characters: text,
            charactersIgnoringModifiers: text,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            FileHandle.standardError.write(Data("FAIL: could not create key event\n".utf8))
            exit(1)
        }
        editor.interpretKeyEvents([event])
    }
}
