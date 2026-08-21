import AppKit

enum OverlayEditCommands {
    private static let keyA: UInt16 = 0
    private static let keyZ: UInt16 = 6
    private static let keyX: UInt16 = 7
    private static let keyC: UInt16 = 8
    private static let keyV: UInt16 = 9

    static func installMainMenu() {
        let appName = "Bubble"
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(menuItem("Quit \(appName)", action: #selector(NSApplication.terminate(_:)), key: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(menuItem("Undo", action: NSSelectorFromString("undo:"), key: "z"))
        editMenu.addItem(menuItem("Redo", action: NSSelectorFromString("redo:"), key: "z", flags: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem("Cut", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(menuItem("Copy", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(menuItem("Paste", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(menuItem("Select All", action: #selector(NSText.selectAll(_:)), key: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    /// Accessory apps do not take the menu bar, so edit shortcuts must be handled directly.
    /// Inspect keyCode and modifierFlags only — reading `characters` in a local key monitor
    /// prevents the field editor / IME from inserting text.
    static func handleCommandEditKey(_ event: NSEvent, paste: (() -> Bool)? = nil) -> Bool {
        guard event.type == .keyDown, isCommandModified(event) else { return false }
        let flags = normalizedFlags(event)
        let commandOnly = flags.contains(.command)
            && !flags.contains(.shift)
            && !flags.contains(.option)
            && !flags.contains(.control)
        let commandShift = flags.contains(.command)
            && flags.contains(.shift)
            && !flags.contains(.option)
            && !flags.contains(.control)

        if commandOnly {
            switch event.keyCode {
            case keyV:
                return paste?() ?? false
            case keyC:
                return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            case keyX:
                return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            case keyA:
                return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            case keyZ:
                return NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil)
            default:
                return false
            }
        }
        if commandShift, event.keyCode == keyZ {
            return NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil)
        }
        return false
    }

    static func isCommandModified(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
    }

    static func insertClipboardText(into current: String, firstResponder: NSResponder?) -> String? {
        guard let snippet = NSPasteboard.general.string(forType: .string), !snippet.isEmpty else {
            return nil
        }
        return insertText(snippet, into: current, firstResponder: firstResponder)
    }

    static func insertText(_ snippet: String, into current: String, firstResponder: NSResponder?) -> String {
        if let textView = firstResponder as? NSTextView, textView.isEditable {
            let range = textView.selectedRange()
            let ns = textView.string as NSString
            if range.location != NSNotFound, NSMaxRange(range) <= ns.length {
                return ns.replacingCharacters(in: range, with: snippet)
            }
        }
        return current + snippet
    }

    static func insertNewline(into current: String, firstResponder: NSResponder?) -> String {
        insertText("\n", into: current, firstResponder: firstResponder)
    }

    private static func normalizedFlags(_ event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function, .help])
    }

    private static func menuItem(
        _ title: String,
        action: Selector?,
        key: String,
        flags: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = flags
        return item
    }
}
