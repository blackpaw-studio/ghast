import Foundation

/// Which images the VM runners use and which are being pulled right now.
struct TartImageUsage: Equatable, Sendable {
    let runnerImages: [RunnerImageUse]
    /// The image refs of the runners that are pulling.
    let pullingImages: Set<String>
}

extension RunnerService {
    /// VM runners' images, read live. A runner that is pulling counts as pulling its image.
    var tartImageUsage: TartImageUsage {
        let uses = localRunners.compactMap { runner -> (RunnerImageUse, isPulling: Bool)? in
            guard case let .tart(image) = runner.backend else { return nil }
            let isPulling = if case .pulling? = processStates[runner.id] { true } else { false }
            return (RunnerImageUse(runnerName: runner.name, image: image), isPulling)
        }
        return TartImageUsage(
            runnerImages: uses.map(\.0),
            pullingImages: Set(uses.filter(\.isPulling).map(\.0.image))
        )
    }
}
