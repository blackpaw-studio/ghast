import AppKit
import SwiftUI

/// A text view for shell scripts. Scripts are code, so no substitution, correction, completion
/// or detection ever runs, whatever the system setting or Edit › Substitutions says.
final class ScriptTextView: NSTextView {
    override var isAutomaticQuoteSubstitutionEnabled: Bool { get { false } set {} }
    override var isAutomaticDashSubstitutionEnabled: Bool { get { false } set {} }
    override var isAutomaticTextReplacementEnabled: Bool { get { false } set {} }
    override var isAutomaticSpellingCorrectionEnabled: Bool { get { false } set {} }
    override var isAutomaticTextCompletionEnabled: Bool { get { false } set {} }
    override var isAutomaticLinkDetectionEnabled: Bool { get { false } set {} }
    override var isAutomaticDataDetectionEnabled: Bool { get { false } set {} }
    override var isContinuousSpellCheckingEnabled: Bool { get { false } set {} }
    override var isGrammarCheckingEnabled: Bool { get { false } set {} }
    override var smartInsertDeleteEnabled: Bool { get { false } set {} }
    override var enabledTextCheckingTypes: NSTextCheckingTypes { get { 0 } set {} }

    /// The script's own history, never the window's: ⌘Z here can only undo this script.
    private let scriptUndoManager = UndoManager()
    override var undoManager: UndoManager? { scriptUndoManager }

    /// Shows another script (a runner switch or an outside change) and forgets the undo history,
    /// which belongs to the old text; replaying it would write one runner's script into another.
    func replaceScript(_ text: String, attributes: [NSAttributedString.Key: Any]) {
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        scriptUndoManager.removeAllActions()
    }
}

/// The job-script editor: `ScriptTextView` in a borderless, scroller-free scroll view, set in
/// the output's monospaced type.
struct ScriptTextEditor: NSViewRepresentable {
    @Binding var text: String
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ScriptTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = FocusMetrics.scriptTextInset
        textView.textContainer?.lineFragmentPadding = FocusMetrics.scriptLinePadding
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = Self.attributes
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel(label)
        Self.setText(text, in: textView)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? ScriptTextView, textView.string != text else { return }
        Self.setText(text, in: textView)
    }

    private static func setText(_ text: String, in textView: ScriptTextView) {
        textView.replaceScript(text, attributes: attributes)
    }

    private static var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = FocusMetrics.scriptLineSpacing
        return [
            .font: NSFont.monospacedSystemFont(ofSize: FocusType.outputSize, weight: .regular),
            .kern: FocusType.outputTracking,
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor.labelColor,
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
