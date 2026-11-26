import Foundation

/// Which images the VM runners use and which are being pulled right now.
struct TartImageUsage: Equatable, Sendable {
    let runnerImages: [RunnerImageUse]
    /// The image refs of the runners that are pulling.
    let pullingImages: Set<String>
}

extension RunnerService {
    /// The images VM runners use, read live: each runner's configured image, plus every image
    /// the backend is actively pulling, cloning or running from, which an edit of the runner's
    /// image doesn't move. A runner that is pulling counts as pulling its image.
    var tartImageUsage: TartImageUsage {
        let configured = localRunners.compactMap { runner -> (RunnerImageUse, isPulling: Bool)? in
            guard case let .tart(image) = runner.backend else { return nil }
            let isPulling = if case .pulling? = processStates[runner.id] { true } else { false }
            return (RunnerImageUse(runnerName: runner.name, image: image), isPulling)
        }
        let active = activeTartImages.compactMap { item -> (RunnerImageUse, isPulling: Bool)? in
            guard let runner = localRunners.first(where: { $0.id == item.runnerID }) else { return nil }
            return (RunnerImageUse(runnerName: runner.name, image: item.image), item.isPulling)
        }
        let all = configured + active
        return TartImageUsage(
            runnerImages: all.map { $0.0 },
            pullingImages: Set(all.filter { $0.isPulling }.map { $0.0.image })
        )
    }
}
