import Foundation
import Observation

/// What New Runner asks for.
struct NewRunnerRequest: Equatable, Sendable {
    let name: String
    let scope: RunnerScope
    let labels: LabelTokenList
    let runnerGroup: String?
    let workFolder: String

    var architecture: HostArchitecture { labels.architecture }

    var registration: RunnerRegistration {
        RunnerRegistration(name: name, scope: scope, customLabels: labels.custom, runnerGroup: runnerGroup, workFolder: workFolder)
    }
}

enum SetupCancelOutcome: Equatable, Sendable {
    case cancelled
    /// GitHub couldn't be told; nothing was trashed. Ask before removing from this Mac only.
    case needsLocalOnlyConfirmation(reason: String)
    /// The folder couldn't be moved to the Trash.
    case failed(String)
}

/// "Setting Up {name}": download → register → start → listen, one step at a time.
///
/// A runner joins the list the moment `config.sh` registers it, so whatever happens next
/// (failure, cancel, quit) it can be found and removed. Cancel waits for the step in flight:
/// a registration is never abandoned half-way, and a finished one is undone.
@MainActor @Observable
final class RunnerSetupFlow {
    enum Phase: Equatable, Sendable {
        case working
        /// Stopped at a failed step; Done reads Try Again.
        case failed(SetupStep)
        /// Listening for jobs; Done is enabled.
        case finished
        case cancelling
        case cancelled
        case needsLocalOnlyConfirmation(reason: String)
    }

    static let connectTimeout: Duration = .seconds(60)
    nonisolated static let didNotConnectMessage = "The runner didn't connect to GitHub."

    private(set) var progress: SetupProgress
    private(set) var phase: Phase = .working
    /// The new runner's id once registered.
    private(set) var runnerID: String?
    /// Cancelling now would unregister a runner on GitHub, which needs the user's go-ahead.
    /// That holds from the moment config.sh starts: it may register before it returns.
    var requiresCancelConfirmation: Bool { runnerID != nil || isRunningConfig }
    /// config.sh is running; its outcome on GitHub isn't known yet.
    private var isRunningConfig = false

    @ObservationIgnored private let request: NewRunnerRequest
    @ObservationIgnored private let services: RunnerFlowServices
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The hidden folder the package downloads into, until registration moves it into place.
    @ObservationIgnored private var stagingFolder: URL?
    /// The runner's folder, once the download moved there.
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var lastDownload: DownloadProgress?
    @ObservationIgnored private var watch: ConnectionWatch?

    init(request: NewRunnerRequest, services: RunnerFlowServices) {
        self.request = request
        self.services = services
        progress = SetupProgress(runnerName: request.name, scopeName: request.scope.displayName)
    }

    private var runnersDirectory: URL { services.runnerService.runnersDirectory }
    private var finalFolder: URL { runnersDirectory.appendingPathComponent(request.name, isDirectory: true) }

    // MARK: Driving

    func start() {
        guard task == nil else { return }
        run(from: .download)
    }

    /// Runs again from the step that failed; finished steps are kept.
    func tryAgain() {
        guard case let .failed(step) = phase else { return }
        run(from: step)
    }

    private func run(from first: SetupStep) {
        phase = .working
        for step in SetupStep.allCases where step >= first { set(step, .pending) }
        task = Task { [weak self] in await self?.perform(from: first) }
    }

    private func perform(from first: SetupStep) async {
        for step in SetupStep.allCases where step >= first {
            guard !Task.isCancelled else { return }
            do {
                try await execute(step)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                await fail(step, message: message(for: error))
                return
            }
        }
        watch = nil
        phase = .finished
    }

    private func execute(_ step: SetupStep) async throws {
        switch step {
        case .download: try await download()
        case .register: try await register()
        case .start: try await startRunner()
        case .listen: try await listen()
        }
    }

    private func fail(_ step: SetupStep, message: String) async {
        set(step, .failed(message))
        watch?.cancel()
        watch = nil
        // A runner that never connected isn't left running behind a failed step.
        if step >= .start, let runnerID { await services.runnerService.stopRunner(id: runnerID) }
        phase = .failed(step)
    }

    // MARK: Steps

    private func download() async throws {
        set(.download, .active(detail: nil))
        if let stagingFolder { try await services.trasher.trash(stagingFolder) }
        stagingFolder = nil
        guard !FileManager.default.fileExists(atPath: finalFolder.path) else {
            throw SetupError.folderExists(request.name)
        }
        let applications = try await services.api.fetchRunnerApplications(for: request.scope)
        guard let package = applications.first(where: { $0.os == "osx" && $0.architecture == request.architecture.rawValue }),
              let url = URL(string: package.downloadURL) else {
            throw SetupError.noPackage(request.architecture)
        }
        progress.version = SetupProgress.version(fromPackage: package.filename)

        let staging = runnersDirectory.appendingPathComponent(".setup-\(request.name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        stagingFolder = staging
        try await services.downloader.install(from: url, into: staging) { [weak self] report in
            Task { @MainActor [weak self] in self?.downloadProgressed(report) }
        }
        // Progress reports hop to the main actor; let them land before the step is marked done.
        await Task.yield()
        set(.download, .done(detail: SetupProgress.downloadedDetail(lastDownload)))
    }

    private func downloadProgressed(_ report: DownloadProgress) {
        lastDownload = report
        guard case .active = progress.state(.download) else { return }
        set(.download, .active(detail: SetupProgress.downloadDetail(report)))
    }

    private func register() async throws {
        set(.register, .active(detail: nil))
        let folder = try moveIntoPlace()
        let token = try await services.api.createRegistrationToken(for: request.scope)
        // Not cancellable from here: once config.sh runs, its result must be recorded.
        isRunningConfig = true
        defer { isRunningConfig = false }
        try await services.registrar.register(request.registration, token: token.token, in: folder)
        var runner = LocalRunner(name: request.name, scope: request.scope, path: folder.path, labels: request.labels.all)
        runner.runnerGroup = request.registration.runnerGroup
        runner.workFolder = request.workFolder
        services.runnerService.addLocalRunner(runner)
        runnerID = runner.id
        set(.register, .done(detail: nil))
    }

    /// Moves the downloaded package from its hidden folder to the runner's folder. Never
    /// replaces a folder that is already there.
    private func moveIntoPlace() throws -> URL {
        if let folder { return folder }
        guard let stagingFolder else { throw SetupError.folderExists(request.name) }
        guard !FileManager.default.fileExists(atPath: finalFolder.path) else { throw SetupError.folderExists(request.name) }
        try FileManager.default.moveItem(at: stagingFolder, to: finalFolder)
        self.stagingFolder = nil
        folder = finalFolder
        return finalFolder
    }

    private func startRunner() async throws {
        guard let runnerID else { throw SetupError.notRegistered }
        set(.start, .active(detail: SetupProgress.connectingDetail))
        await services.runnerService.stopRunner(id: runnerID)
        let (_, before) = services.readRunner(runnerID)
        try await services.runnerService.startRunner(id: runnerID)
        let watch = ConnectionWatch(
            runnerID: runnerID,
            baseline: before.lines.last?.id,
            read: services.readRunner
        )
        self.watch = watch
        watch.startTimeout(after: Self.connectTimeout, sleeper: services.sleeper)
        try await watch.wait(for: .connected)
        set(.start, .done(detail: nil))
    }

    private func listen() async throws {
        guard let watch else { throw SetupError.notRegistered }
        set(.listen, .active(detail: nil))
        try await watch.wait(for: .listening)
        watch.cancel()
        set(.listen, .done(detail: nil))
    }

    // MARK: Cancel

    /// Stops the step in flight (waiting for a registration to finish), then undoes what was
    /// done: a registered runner is removed like Remove Runner; otherwise the partial download
    /// goes to the Trash.
    func cancel() async -> SetupCancelOutcome {
        phase = .cancelling
        task?.cancel()
        watch?.cancel()
        await task?.value
        task = nil
        watch = nil
        let outcome = await undo()
        switch outcome {
        case .cancelled: phase = .cancelled
        case let .needsLocalOnlyConfirmation(reason): phase = .needsLocalOnlyConfirmation(reason: reason)
        case .failed: phase = .cancelled
        }
        return outcome
    }

    /// After a refused GitHub removal, removes the runner from this Mac only.
    func removeFromThisMacOnly() async throws {
        if let runner = registeredRunner {
            try await services.remover.removeFromThisMacOnly(runner)
        }
        phase = .cancelled
    }

    private var registeredRunner: LocalRunner? {
        runnerID.flatMap { id in services.runnerService.localRunners.first { $0.id == id } }
    }

    private func undo() async -> SetupCancelOutcome {
        do {
            if let runner = registeredRunner {
                switch try await services.remover.remove(runner, gitHubRunnerID: nil) {
                case .removed: return .cancelled
                case let .needsLocalOnlyConfirmation(reason): return .needsLocalOnlyConfirmation(reason: reason)
                }
            }
            // Only folders this flow made: its hidden download, or the runner's folder it moved
            // into place before registration failed.
            for made in [stagingFolder, folder].compactMap({ $0 }) where FileManager.default.fileExists(atPath: made.path) {
                try await services.trasher.trash(made)
            }
            stagingFolder = nil
            folder = nil
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: -

    private func set(_ step: SetupStep, _ state: SetupStepState) {
        progress = progress.setting(step, state)
    }

    private func message(for error: Error) -> String {
        if let apiError = error as? GitHubAPIError { return request.scope.errorMessage(for: apiError) }
        return error.localizedDescription
    }
}

enum SetupError: LocalizedError, Equatable {
    case folderExists(String)
    case noPackage(HostArchitecture)
    case notRegistered

    var errorDescription: String? {
        switch self {
        case let .folderExists(name): "A folder named \(name) already exists in the runners folder."
        case let .noPackage(architecture): "GitHub has no runner for macOS \(architecture.runnerLabel)."
        case .notRegistered: "The runner isn't registered yet."
        }
    }
}
