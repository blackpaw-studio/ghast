import Foundation
import Testing
@testable import Ghast

@MainActor
@Suite("Notification policy", .serialized, .timeLimit(.minutes(1)))
struct NotificationPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func exit(_ code: Int32, requested: Bool = false) -> RunnerExit {
        RunnerExit(code: code, startedAt: nil, at: now, wasRequested: requested)
    }

    private func failedJob(_ name: String = "build-and-notarize", result: JobResult = .failed) -> JobRecord {
        JobRecord(name: name, result: result, startedAt: now, finishedAt: now)
    }

    private struct Harness {
        let service: NotificationService
        let center: FakeNotificationCenter
        let settings: AppSettings
        let opened: OpenLog
        let cleanup: () -> Void
    }

    @MainActor final class OpenLog { var ids: [String] = [] }

    private func makeHarness(names: [String: String] = ["r1": "ghast-release"]) -> Harness {
        let isolated = makeIsolatedDefaults()
        let settings = AppSettings(defaults: isolated.defaults)
        let center = FakeNotificationCenter()
        let opened = OpenLog()
        let service = NotificationService(
            center: center,
            settings: settings,
            runnerName: { names[$0] },
            openRunner: { opened.ids.append($0) }
        )
        return Harness(service: service, center: center, settings: settings, opened: opened, cleanup: isolated.cleanup)
    }

    // MARK: Policy

    @Test("an unexpected exit notifies by default, with the spec's words")
    func unexpectedExitNotifies() async {
        let h = makeHarness()
        defer { h.cleanup() }

        await h.service.handle(.processExited(RunnerProcessExit(runnerID: "r1", exit: exit(1))))

        #expect(h.center.posted == [RunnerNotice(
            kind: .unexpectedStop,
            runnerID: "r1",
            title: "ghast-release stopped unexpectedly",
            body: "The runner exited with code 1. Click to see its output."
        )])
    }

    @Test("requested stops and quits never notify", arguments: [Int32(143), 137, 1])
    func requestedStopIsSilent(code: Int32) async {
        let h = makeHarness()
        defer { h.cleanup() }

        await h.service.handle(.processExited(RunnerProcessExit(runnerID: "r1", exit: exit(code, requested: true))))

        #expect(h.center.posted.isEmpty)
        #expect(h.center.requestCount == 0)
    }

    @Test("self-update exits (0 and 2) never notify, as a process exit or a logged one", arguments: [Int32(0), 2])
    func selfUpdateIsSilent(code: Int32) async {
        let h = makeHarness()
        defer { h.cleanup() }

        await h.service.handle(.processExited(RunnerProcessExit(runnerID: "r1", exit: exit(code))))
        await h.service.handle(.live(.exited(runnerID: "r1", exit: LoggedExit(code: code, at: now))))

        #expect(h.center.posted.isEmpty)
    }

    @Test("a logged exit marker never notifies: the process exit is the authority")
    func loggedExitIsSilent() async {
        let h = makeHarness()
        defer { h.cleanup() }

        await h.service.handle(.live(.exited(runnerID: "r1", exit: LoggedExit(code: 143, at: now))))

        #expect(h.center.posted.isEmpty)
    }

    @Test("turning off unexpected-stop notifications silences them")
    func unexpectedStopOptOut() async {
        let h = makeHarness()
        defer { h.cleanup() }
        h.settings.notifyUnexpectedStop = false

        await h.service.handle(.processExited(RunnerProcessExit(runnerID: "r1", exit: exit(1))))

        #expect(h.center.posted.isEmpty)
    }

    @Test("a runner that is gone by the time it exits is not announced")
    func unknownRunnerIsSilent() async {
        let h = makeHarness(names: [:])
        defer { h.cleanup() }

        await h.service.handle(.processExited(RunnerProcessExit(runnerID: "r1", exit: exit(1))))

        #expect(h.center.posted.isEmpty)
    }

    @Test("a failed job notifies only when opted in")
    func jobFailureIsOptIn() async {
        let h = makeHarness()
        defer { h.cleanup() }

        await h.service.handle(.live(.jobFinished(runnerID: "r1", job: failedJob())))
        #expect(h.center.posted.isEmpty)

        h.settings.notifyJobFailure = true
        await h.service.handle(.live(.jobFinished(runnerID: "r1", job: failedJob())))
        await h.service.handle(.live(.jobFinished(runnerID: "r1", job: failedJob("lint", result: .succeeded))))
        await h.service.handle(.live(.jobFinished(runnerID: "r1", job: failedJob("tests", result: .cancelled))))

        #expect(h.center.posted == [RunnerNotice(
            kind: .jobFailed,
            runnerID: "r1",
            title: "build-and-notarize failed on ghast-release",
            body: "Click to see its output."
        )])
    }

    // MARK: Sources

    @Test("a requested stop or a retried exit never notifies; giving up after the retries does")
    func serviceExitsDriveNotifications() async throws {
        let h = makeHarness(names: [:])
        defer { h.cleanup() }
        let folder = makeTemporaryDirectory()
        let launcher = ControllableLauncher(log: CallLog())
        let runner = LocalRunner(name: "ghast-release", scope: .organization(login: "blackpaw-studio"), path: folder.path)
        let isolated = makeIsolatedDefaults()
        defer { isolated.cleanup() }
        let retries = ManualSleeper()
        let runnerService = RunnerService(
            defaults: isolated.defaults,
            runnersDirectory: makeTemporaryDirectory(),
            launcher: launcher,
            sleeper: { _ in },
            scanner: NoRunnerProcessScanner(),
            recoverySleeper: retries.sleeper
        )
        runnerService.addLocalRunner(runner)
        let service = NotificationService(
            center: h.center,
            settings: h.settings,
            runnerName: { id in runnerService.localRunners.first { $0.id == id }?.name },
            openRunner: { _ in }
        )
        let consuming = Task { await service.run(liveEvents: AsyncStream { $0.finish() }, processExits: runnerService.processExits) }
        defer { consuming.cancel() }

        try await runnerService.startRunner(id: runner.id)
        let stopping = Task { await runnerService.stopRunner(id: runner.id) }
        await Task.yield()
        launcher.exit(folder.lastPathComponent, code: 143)
        await stopping.value

        try await runnerService.startRunner(id: runner.id)
        // Three retries each fail again; only the exit after the last one is announced.
        for _ in 0..<3 {
            launcher.exit(folder.lastPathComponent, code: 1)
            for _ in 0..<12 { await Task.yield() }
            #expect(h.center.posted.isEmpty)
            retries.wakeAll()
            for _ in 0..<12 { await Task.yield() }
        }
        launcher.exit(folder.lastPathComponent, code: 1)

        let notice = await h.center.nextPost()
        #expect(notice.kind == .unexpectedStop)
        #expect(h.center.posted.count == 1)
    }

    @Test("only live events notify: a failed job already in the log at launch is never announced")
    func backlogIsSilent() async throws {
        let h = makeHarness(names: [:])
        defer { h.cleanup() }
        h.settings.notifyJobFailure = true
        let folder = makeTemporaryDirectory()
        let log = folder.appendingPathComponent(RunnerWrapperScript.logFileName)
        let line = { (time: String, text: String) in "2026-11-16T\(time)-0500 \(text)\n" }
        try (line("09:00:00", "Running job: old") + line("09:05:00", "Job old completed with result: Failed")
            + line("09:06:00", "ghast: exit code=1")).write(to: log, atomically: true, encoding: .utf8)
        let runner = LocalRunner(name: "dionysus-xcode", scope: .organization(login: "blackpaw-studio"), path: folder.path)
        let store = RunnerActivityStore()
        let service = NotificationService(
            center: h.center,
            settings: h.settings,
            runnerName: { $0 == runner.id ? runner.name : nil },
            openRunner: { _ in }
        )
        let consuming = Task { await service.run(liveEvents: store.liveEvents, processExits: AsyncStream { $0.finish() }) }
        store.track([runner])

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line("10:00:00", "Running job: build") + line("10:05:00", "Job build completed with result: Failed")).utf8))
        try handle.close()

        let notice = await h.center.nextPost()
        #expect(notice.title == "build failed on dionysus-xcode")
        #expect(h.center.posted.count == 1)
        consuming.cancel()
        await store.shutdown()
    }

    // MARK: Permission

    @Test("permission is asked once, on the first post")
    func asksOnceOnFirstPost() async {
        let h = makeHarness()
        defer { h.cleanup() }

        await h.service.handle(.processExited(RunnerProcessExit(runnerID: "r1", exit: exit(1))))
        await h.service.handle(.processExited(RunnerProcessExit(runnerID: "r1", exit: exit(1))))
        await h.service.notifyToggleTurnedOn()

        #expect(h.center.requestCount == 1)
        #expect(h.center.posted.count == 2)
        #expect(h.settings.notificationPermissionRequested)
    }

    @Test("permission is asked the first time a notify toggle is switched on, and not again on a post")
    func asksOnFirstToggle() async {
        let h = makeHarness()
        defer { h.cleanup() }

        await h.service.notifyToggleTurnedOn()
        #expect(h.center.requestCount == 1)

        await h.service.handle(.processExited(RunnerProcessExit(runnerID: "r1", exit: exit(1))))
        await h.service.notifyToggleTurnedOn()
        #expect(h.center.requestCount == 1)
        #expect(h.center.posted.count == 1)
    }

    @Test("denied permission stays silent and is never asked again")
    func deniedIsSilent() async {
        let h = makeHarness()
        defer { h.cleanup() }
        h.center.grants = false

        await h.service.handle(.processExited(RunnerProcessExit(runnerID: "r1", exit: exit(1))))
        await h.service.handle(.processExited(RunnerProcessExit(runnerID: "r1", exit: exit(1))))

        #expect(h.center.posted.isEmpty)
        #expect(h.center.requestCount == 1)
        #expect(h.service.authorization == .denied)
    }

    @Test("permission asked in an earlier session is not asked again; a later denial in System Settings silences")
    func earlierAnswerIsRespected() async {
        let h = makeHarness()
        defer { h.cleanup() }
        h.settings.notificationPermissionRequested = true
        h.center.status = .denied

        await h.service.handle(.processExited(RunnerProcessExit(runnerID: "r1", exit: exit(1))))

        #expect(h.center.requestCount == 0)
        #expect(h.center.posted.isEmpty)
    }

    // MARK: Click

    @Test("clicking a notification opens that runner's output")
    func clickOpensRunner() {
        let h = makeHarness()
        defer { h.cleanup() }

        h.center.click(runnerID: "r1")

        #expect(h.opened.ids == ["r1"])
    }
}
