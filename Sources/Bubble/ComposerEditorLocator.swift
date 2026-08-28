import AppKit

/// Resolves the native AppKit field editor that backs Bubble's SwiftUI composer.
/// SwiftUI may replace that editor while a turn starts or is cancelled, so the
/// resolver keys ownership to the actual NSTextField instead of a stale editor.
enum ComposerEditorLocator {
    static func matchingTextField(in root: NSView, alignedWith probe: NSView) -> NSTextField? {
        let probeFrame = probe.convert(probe.bounds, to: root)
        guard probeFrame.width > 0, probeFrame.height > 0 else { return nil }

        return editableTextFields(in: root)
            .compactMap { field -> (field: NSTextField, overlap: CGFloat, distance: CGFloat)? in
                let fieldFrame = field.convert(field.bounds, to: root)
                let intersection = fieldFrame.intersection(probeFrame)
                guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
                    return nil
                }
                let overlap = intersection.width * intersection.height
                let distance = hypot(fieldFrame.midX - probeFrame.midX, fieldFrame.midY - probeFrame.midY)
                return (field, overlap, distance)
            }
            .max {
                if abs($0.overlap - $1.overlap) > 0.5 {
                    return $0.overlap < $1.overlap
                }
                return $0.distance > $1.distance
            }?
            .field
    }

    static func composerField(in root: NSView) -> NSTextField? {
        let fields = editableTextFields(in: root)
        if let active = activeTextField(in: root.window),
           fields.contains(where: { $0 === active }),
           isLowestField(active, among: fields) {
            return active
        }
        if let identified = fields.first(where: {
            $0.identifier?.rawValue == ComposerEditorIdentity.viewIdentifier
        }) {
            return identified
        }

        // The composer is the lowest editable field in the overlay. Palette
        // search fields are rendered above it and must keep their own focus.
        return fields.min {
            windowMidY(of: $0) < windowMidY(of: $1)
        }
    }

    static func markComposerField(_ field: NSTextField) {
        let identifier = NSUserInterfaceItemIdentifier(ComposerEditorIdentity.viewIdentifier)
        field.identifier = identifier
        if let editor = field.window?.fieldEditor(false, for: field) as? NSTextView,
           editor.delegate as? NSTextField === field {
            editor.identifier = identifier
        }
    }

    static func ensureFieldEditor(
        in window: NSWindow,
        composerField: NSTextField?
    ) -> NSTextView? {
        guard let composerField else { return nil }
        markComposerField(composerField)
        window.makeKey()

        if let editor = window.firstResponder as? NSTextView, editor.isEditable {
            guard editor.delegate as? NSTextField === composerField else { return nil }
            editor.identifier = NSUserInterfaceItemIdentifier(ComposerEditorIdentity.viewIdentifier)
            return editor
        }

        if let field = window.firstResponder as? NSTextField,
           field.isEditable,
           field !== composerField {
            return nil
        }

        guard window.makeFirstResponder(composerField),
              let editor = window.firstResponder as? NSTextView,
              editor.isEditable,
              editor.delegate as? NSTextField === composerField else {
            return nil
        }
        editor.identifier = NSUserInterfaceItemIdentifier(ComposerEditorIdentity.viewIdentifier)
        return editor
    }

    /// Restores keyboard ownership after a transient overlay control (such as
    /// Scroll to end) takes first responder and then disappears.
    static func restoreComposerFocus(in window: NSWindow, root: NSView) -> NSTextView? {
        ensureFieldEditor(in: window, composerField: composerField(in: root))
    }

    static func releaseFieldEditor(in window: NSWindow) {
        window.makeFirstResponder(nil)
    }

    private static func editableTextFields(in view: NSView) -> [NSTextField] {
        var fields: [NSTextField] = []
        if let field = view as? NSTextField,
           field.isEditable,
           !field.isHidden,
           field.alphaValue > 0.01 {
            fields.append(field)
        }
        for child in view.subviews {
            fields.append(contentsOf: editableTextFields(in: child))
        }
        return fields
    }

    private static func activeTextField(in window: NSWindow?) -> NSTextField? {
        if let editor = window?.firstResponder as? NSTextView {
            return editor.delegate as? NSTextField
        }
        return window?.firstResponder as? NSTextField
    }

    private static func isLowestField(_ field: NSTextField, among fields: [NSTextField]) -> Bool {
        guard let lowestY = fields.map(windowMidY(of:)).min() else { return false }
        return windowMidY(of: field) <= lowestY + 1
    }

    private static func windowMidY(of view: NSView) -> CGFloat {
        view.convert(view.bounds, to: nil).midY
    }
}
