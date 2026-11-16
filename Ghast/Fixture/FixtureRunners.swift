#if DEBUG
import Foundation

/// How a fixture runner's process behaves once seeded: it started at `startedAt` and either
/// is still running or ended at `endedAt` with `exitCode`. Times are "HH:MM:SS" on the kit's day.
struct FixtureProcessScript: Sendable {
    let startedAt: String
    let exit: (code: Int32, at: String)?

    static func running(since startedAt: String) -> FixtureProcessScript {
        FixtureProcessScript(startedAt: startedAt, exit: nil)
    }

    static func exited(code: Int32, startedAt: String, at: String) -> FixtureProcessScript {
        FixtureProcessScript(startedAt: startedAt, exit: (code, at))
    }
}

/// One runner on the fixture Mac: what is on disk and how its process was left.
struct FixtureRunnerSpec: Sendable {
    let name: String
    let scope: RunnerScope
    let labels: [String]
    let log: @Sendable (TimeZone) -> String
    let process: FixtureProcessScript
    var environmentVariables: [String: String] = [:]
    var preJobScript: String?
}

extension FixtureWorld {
    /// The three runners on this Mac in the design kit, in the order the kit seeds them.
    static let localRunners: [FixtureRunnerSpec] = [
        FixtureRunnerSpec(
            name: "dionysus-arm64",
            scope: organizationScope,
            labels: ["self-hosted", "macOS", "ARM64"],
            log: { FixtureLogs.dionysusArm64(timeZone: $0) },
            process: .running(since: "08:12:29")
        ),
        FixtureRunnerSpec(
            name: "dionysus-xcode",
            scope: organizationScope,
            labels: ["self-hosted", "macOS", "ARM64", "xcode"],
            log: { FixtureLogs.dionysusXcode(timeZone: $0) },
            // Uptime 3 h 14 min at 10:12.
            process: .running(since: "06:58:02"),
            environmentVariables: [
                "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                "HOMEBREW_NO_AUTO_UPDATE": "1",
            ],
            preJobScript: "#!/bin/sh\nxcodebuild -runFirstLaunch\nsecurity unlock-keychain -p \"$KEYCHAIN_PASSWORD\" build.keychain"
        ),
        FixtureRunnerSpec(
            name: "ghast-release",
            scope: repositoryScope,
            labels: ["self-hosted", "macOS", "ARM64"],
            log: { FixtureLogs.ghastRelease(timeZone: $0) },
            // Last Run 1 h 02 min: 09:03:40 to 10:05:11 is 61.5 minutes.
            process: .exited(code: 1, startedAt: "09:03:40", at: "10:05:11")
        ),
    ]
}
#endif
