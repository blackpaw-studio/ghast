import AppKit

/// Menu key equivalents reach the main menu before a focused text view sees the key, so ⌘⌫
/// (Remove Runner…) would steal "delete to the start of the line" from every text field.
@MainActor
enum TextEditingKeyRouting {
    /// When ⌘⌫ was typed into an editable text field or text view, deletes to the start of the
    /// line there and returns true. A click on the menu item still removes.
    static func deleteToLineStartIfEditing(event: NSEvent? = NSApp.currentEvent, window: NSWindow? = NSApp.keyWindow) -> Bool {
        guard event?.type == .keyDown,
              let textView = window?.firstResponder as? NSTextView,
              textView.isEditable else { return false }
        textView.deleteToBeginningOfLine(nil)
        return true
    }
}
