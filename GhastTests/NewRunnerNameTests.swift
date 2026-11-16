import Testing
import Foundation
@testable import Ghast

@Suite struct NewRunnerNameTests {
    let org = RunnerScope.organization(login: "blackpaw-studio")
    let repo = RunnerScope.repository(fullName: "blackpaw-studio/ghast")

    func local(_ name: String, _ scope: RunnerScope) -> LocalRunner {
        LocalRunner(name: name, scope: scope, path: "/tmp/\(name)")
    }

    var kitRunners: [LocalRunner] {
        [local("dionysus-arm64", org), local("dionysus-xcode", org), local("ghast-release", repo)]
    }

    // MARK: Suggested name

    @Test func suggestionCountsThisMacsRunnersInTheScope() {
        // NewRunner.png: two runners on this Mac in blackpaw-studio → "dionysus-3".
        let name = NewRunnerName.suggested(hostName: "Dionysus", scope: org, localRunners: kitRunners, gitHubNames: [])
        #expect(name == "dionysus-3")
    }

    @Test func suggestionStartsAtOneWithNoRunnersInTheScope() {
        let name = NewRunnerName.suggested(hostName: "Dionysus", scope: .organization(login: "other"), localRunners: kitRunners, gitHubNames: [])
        #expect(name == "dionysus-1")
    }

    @Test func suggestionIsBumpedPastNamesTakenOnGitHubAndThisMac() {
        let runners = kitRunners + [local("dionysus-4", repo)]
        let name = NewRunnerName.suggested(hostName: "Dionysus", scope: org, localRunners: runners, gitHubNames: ["Dionysus-3", "dionysus-5"])
        #expect(name == "dionysus-6")
    }

    @Test func suggestionSlugsTheComputerName() {
        let name = NewRunnerName.suggested(hostName: "Evan’s MacBook Pro", scope: org, localRunners: [], gitHubNames: [])
        #expect(name == "evan-s-macbook-pro-1")
    }

    @Test func suggestionFallsBackWhenTheComputerNameHasNoUsableCharacters() {
        #expect(NewRunnerName.suggested(hostName: "☃︎", scope: org, localRunners: [], gitHubNames: []) == "mac-1")
    }

    // MARK: Validation

    @Test func freeNameIsValid() {
        #expect(NewRunnerName.validate("dionysus-3", scope: org, localRunners: kitRunners, gitHubNames: ["helios-linux"]) == .valid)
    }

    @Test func clashOnGitHubInTheScopeIsCaseInsensitive() {
        let result = NewRunnerName.validate("HELIOS-linux", scope: org, localRunners: [], gitHubNames: ["helios-linux"])
        #expect(result == .clash)
        #expect(result.message(scope: org, name: "HELIOS-linux") == "A runner named HELIOS-linux already exists in blackpaw-studio.")
    }

    @Test func clashWithARunnerOnThisMacInTheScope() {
        let result = NewRunnerName.validate("dionysus-xcode", scope: org, localRunners: kitRunners, gitHubNames: [])
        #expect(result == .clash)
        #expect(result.message(scope: org, name: "dionysus-xcode") == "A runner named dionysus-xcode already exists in blackpaw-studio.")
    }

    @Test func runnerOnThisMacInAnotherScopeStillClashesBecauseFoldersAreNamedAfterRunners() {
        let result = NewRunnerName.validate("ghast-release", scope: org, localRunners: kitRunners, gitHubNames: [])
        #expect(result == .takenOnThisMac)
        #expect(result.message(scope: org, name: "ghast-release") == "A runner named ghast-release already exists on this Mac.")
    }

    @Test(arguments: ["", "   "])
    func emptyNameIsInvalidWithoutAMessage(_ name: String) {
        let result = NewRunnerName.validate(name, scope: org, localRunners: [], gitHubNames: [])
        #expect(result == .empty)
        #expect(result.message(scope: org, name: name) == nil)
    }

    @Test(arguments: ["has space", "slash/name", ".hidden", "dots..", "name,comma", String(repeating: "a", count: 65)])
    func unsafeNamesAreInvalid(_ name: String) {
        let result = NewRunnerName.validate(name, scope: org, localRunners: [], gitHubNames: [])
        #expect(result == .invalidCharacters)
        #expect(result.message(scope: org, name: name) == "Use up to 64 letters, numbers, hyphens, underscores or periods.")
    }

    // MARK: Create button

    @Test func createNeedsAValidNameAndAScope() {
        #expect(NewRunnerName.canCreate(name: "dionysus-3", scope: org, localRunners: kitRunners, gitHubNames: []))
        #expect(!NewRunnerName.canCreate(name: "dionysus-3", scope: nil, localRunners: kitRunners, gitHubNames: []))
        #expect(!NewRunnerName.canCreate(name: "", scope: org, localRunners: kitRunners, gitHubNames: []))
        #expect(!NewRunnerName.canCreate(name: "dionysus-xcode", scope: org, localRunners: kitRunners, gitHubNames: []))
    }
}
