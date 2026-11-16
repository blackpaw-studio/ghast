import Testing
@testable import Ghast

@Suite struct LabelTokenTests {
    @Test(arguments: [(HostArchitecture.arm64, "ARM64"), (.x64, "X64")])
    func defaultsFollowTheArchitecture(_ architecture: HostArchitecture, _ label: String) {
        let tokens = LabelTokenList(architecture: architecture)
        #expect(tokens.defaults == ["self-hosted", "macOS", label])
        #expect(tokens.custom.isEmpty)
        #expect(tokens.all == ["self-hosted", "macOS", label])
    }

    @Test func changingTheArchitectureKeepsCustomLabels() {
        let tokens = LabelTokenList(architecture: .arm64).committing("xcode").tokens.with(architecture: .x64)
        #expect(tokens.all == ["self-hosted", "macOS", "X64", "xcode"])
    }

    @Test func returnCommitsTheTypedText() {
        let edit = LabelTokenList(architecture: .arm64).committing("  xcode ")
        #expect(edit.tokens.custom == ["xcode"])
        #expect(edit.remainder == "")
    }

    @Test func aCommaCommitsWhatCameBeforeItAndKeepsTheRest() {
        let edit = LabelTokenList(architecture: .arm64).typing("xcode,gpu, metal")
        #expect(edit.tokens.custom == ["xcode", "gpu"])
        #expect(edit.remainder == " metal")
    }

    @Test func typingWithoutACommaCommitsNothing() {
        let edit = LabelTokenList(architecture: .arm64).typing("xco")
        #expect(edit.tokens.custom.isEmpty)
        #expect(edit.remainder == "xco")
    }

    @Test(arguments: ["xcode", "XCODE", "macos", "arm64"])
    func duplicatesAreRejectedIgnoringCase(_ text: String) {
        let tokens = LabelTokenList(architecture: .arm64).committing("xcode").tokens
        let edit = tokens.committing(text)
        #expect(edit.tokens == tokens)
        #expect(edit.remainder == text)
    }

    @Test(arguments: ["", "   ", "two words", "tab\there"])
    func blankOrSpacedLabelsAreRejected(_ text: String) {
        let edit = LabelTokenList(architecture: .arm64).committing(text)
        #expect(edit.tokens.custom.isEmpty)
        #expect(edit.remainder == (text.allSatisfy(\.isWhitespace) ? "" : text))
    }

    @Test func removingACustomLabel() {
        let tokens = LabelTokenList(architecture: .arm64).typing("xcode,gpu,").tokens.removing("xcode")
        #expect(tokens.custom == ["gpu"])
    }

    @Test func defaultLabelsCannotBeRemoved() {
        let tokens = LabelTokenList(architecture: .arm64).removing("macOS")
        #expect(tokens.all == ["self-hosted", "macOS", "ARM64"])
    }

    @Test func customLabelsFromASavedListDropTheDefaults() {
        #expect(LabelTokenList.customLabels(in: ["self-hosted", "macOS", "ARM64", "xcode"]) == ["xcode"])
        #expect(LabelTokenList.customLabels(in: ["self-hosted", "macOS", "X64", "gpu"]) == ["gpu"])
    }
}
