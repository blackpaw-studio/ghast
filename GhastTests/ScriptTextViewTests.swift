import Testing
import AppKit
@testable import Ghast

/// Job scripts are code: no substitution may ever touch them, whatever the system setting
/// or Edit › Substitutions says.
@MainActor @Suite struct ScriptTextViewTests {
    @Test func everySubstitutionStaysOffEvenWhenTurnedOn() {
        let view = ScriptTextView()
        view.isAutomaticQuoteSubstitutionEnabled = true
        view.isAutomaticDashSubstitutionEnabled = true
        view.isAutomaticTextReplacementEnabled = true
        view.isAutomaticSpellingCorrectionEnabled = true
        view.isAutomaticTextCompletionEnabled = true
        view.isAutomaticLinkDetectionEnabled = true
        view.isAutomaticDataDetectionEnabled = true
        view.isContinuousSpellCheckingEnabled = true
        view.isGrammarCheckingEnabled = true

        #expect(!view.isAutomaticQuoteSubstitutionEnabled)
        #expect(!view.isAutomaticDashSubstitutionEnabled)
        #expect(!view.isAutomaticTextReplacementEnabled)
        #expect(!view.isAutomaticSpellingCorrectionEnabled)
        #expect(!view.isAutomaticTextCompletionEnabled)
        #expect(!view.isAutomaticLinkDetectionEnabled)
        #expect(!view.isAutomaticDataDetectionEnabled)
        #expect(!view.isContinuousSpellCheckingEnabled)
        #expect(!view.isGrammarCheckingEnabled)
    }
}

/// One editor shows each runner in turn: its undo history must not survive a switch, or ⌘Z
/// would write the previous runner's script into the next one.
@MainActor @Suite struct ScriptTextViewUndoTests {
    @Test func replacingTheScriptForgetsTheUndoHistory() {
        let view = ScriptTextView()
        view.allowsUndo = true
        view.replaceScript("echo a", attributes: [:])
        view.insertText(" # edited", replacementRange: NSRange(location: 6, length: 0))
        view.breakUndoCoalescing()
        #expect(view.undoManager?.canUndo == true)

        view.replaceScript("echo b", attributes: [:])

        #expect(view.undoManager?.canUndo == false)
        #expect(view.string == "echo b")
    }
}
