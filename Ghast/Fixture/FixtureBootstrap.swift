#if DEBUG
import Foundation

/// Reads the process arguments once at launch and builds the fixture world, if asked for.
@MainActor
enum FixtureBootstrap {
    struct Result {
        let dependencies: FixtureDependencies
        let stage: FixtureStage
    }

    /// nil on a normal launch. A malformed fixture flag exits with status 2 instead of
    /// launching against the user's real data.
    static func fromProcessArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Result? {
        do {
            guard let launch = try FixtureLaunch.parse(arguments) else { return nil }
            let dependencies = FixtureDependencies.make(for: launch)
            let stage = FixtureStage(
                launch: launch,
                removeScratch: { dependencies.tearDown() },
                prepare: {
                    await dependencies.seedProcessStates()
                    await dependencies.appDependencies.startServices()
                }
            )
            return Result(dependencies: dependencies, stage: stage)
        } catch {
            FileHandle.standardError.write(Data("ghast: \(error)\n".utf8))
            exit(2)
        }
    }
}
#endif
