import AppKit
import Testing
@testable import Ghast

/// ⌘⌫ is Remove Runner…, but inside a text field it must still delete to the line start.
@MainActor @Suite struct TextEditingKeyRoutingTests {
    private func window(editing text: String, editable: Bool = true) -> (NSWindow, NSTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let textView = NSTextView(frame: window.contentRect(forFrameRect: window.frame))
        textView.string = text
        textView.isEditable = editable
        window.contentView = textView
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return (window, textView)
    }

    private var commandDelete: NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                         context: nil, characters: "\u{8}", charactersIgnoringModifiers: "\u{8}", isARepeat: false, keyCode: 51)
    }

    @Test func typedInATextViewDeletesToLineStartInstead() {
        let (window, textView) = window(editing: "first\nKEY=value")

        #expect(TextEditingKeyRouting.deleteToLineStartIfEditing(event: commandDelete, window: window))
        #expect(textView.string == "first\n")
    }

    @Test func aMenuClickStillRemoves() {
        let (window, textView) = window(editing: "KEY=value")
        let click = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 0)

        #expect(!TextEditingKeyRouting.deleteToLineStartIfEditing(event: click, window: window))
        #expect(textView.string == "KEY=value")
    }

    @Test func readOnlyTextDoesNotSwallowTheShortcut() {
        let (window, _) = window(editing: "log line", editable: false)
        #expect(!TextEditingKeyRouting.deleteToLineStartIfEditing(event: commandDelete, window: window))
    }
}
