import Testing
@testable import Ghast

@Suite struct RunnerConfigArgumentsTests {
    @Test func organizationRegistrationPassesGroupWorkFolderAndCustomLabels() {
        let arguments = RunnerService.configArguments(
            url: RunnerScope.organization(login: "acme").configURL,
            token: "TOKEN",
            name: "org-runner",
            labels: ["xcode"],
            runnerGroup: "macOS builders",
            workFolder: "_work"
        )

        #expect(arguments == [
            "./config.sh",
            "--url", "https://github.com/acme",
            "--token", "TOKEN",
            "--name", "org-runner",
            "--unattended",
            "--work", "_work",
            "--labels", "xcode",
            "--runnergroup", "macOS builders",
        ])
    }

    @Test func repositoryRegistrationWithoutLabelsOrGroup() {
        let arguments = RunnerService.configArguments(
            url: RunnerScope.repository(fullName: "octo/ghast").configURL,
            token: "TOKEN",
            name: "repo-runner",
            labels: [],
            runnerGroup: nil,
            workFolder: "builds"
        )

        #expect(arguments == [
            "./config.sh",
            "--url", "https://github.com/octo/ghast",
            "--token", "TOKEN",
            "--name", "repo-runner",
            "--unattended",
            "--work", "builds",
        ])
    }

    @Test func reconfigureReplacesTheRegistrationWithTheSameName() {
        let arguments = RunnerService.configArguments(
            url: "https://github.com/acme",
            token: "NEW",
            name: "org-runner",
            labels: ["xcode"],
            runnerGroup: "Default",
            workFolder: "_work",
            replace: true
        )

        #expect(arguments.last == "--replace")
        #expect(arguments.filter { $0 == "--replace" }.count == 1)
    }

    @Test func removeArgumentsUnregisterWithTheRemovalToken() {
        #expect(RunnerService.removeArguments(token: "RM") == ["./config.sh", "remove", "--token", "RM"])
    }
}
