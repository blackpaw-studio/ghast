import Testing
import Foundation
@testable import Ghast

@MainActor @Suite struct DemandSourceFactoryTests {
    let clock = FakeClock()
    let api = MockGitHubAPIService()
    let sleeper = ManualSleeper()
    let demand = DemandRecorder()

    private func makeFactory(_ replies: [FakeTransport.Reply]) -> (DemandSourceFactory, FakeTransport) {
        let transport = FakeTransport(replies)
        let factory = DemandSourceFactory(
            api: api, transport: transport, clock: clock, sleeper: sleeper.sleeper,
            ownerName: "Dionysus", retry: .init(maxRetries: 0)
        )
        return (factory, transport)
    }

    private func runner(_ scope: RunnerScope) -> LocalRunner {
        var runner = LocalRunner(name: "mac-vm", scope: scope, path: "/tmp/ghast-test-runner")
        runner.backend = .tart(image: "ghcr.io/cirruslabs/macos-tahoe-xcode:latest")
        return runner
    }

    private static let rejected = FakeTransport.Reply.json(#"{"message":"no"}"#, status: 403)

    @Test("a repository runner whose token scale sets refuse falls back to REST polling")
    func repositoryFallsBack() async throws {
        let (factory, _) = makeFactory([Self.rejected])
        let source = factory.make(for: runner(.repository(fullName: "octo/ghast")))
        let recorder = demand
        let task = Task { try await source.run(recorder.context) }
        while demand.values.isEmpty { await Task.yield() }
        task.cancel()
        sleeper.wakeAll()
        _ = await task.result
        #expect(api.conditionalFetches.first?.key == "runs:queued")
    }

    @Test("an organization runner whose token scale sets refuse stops with a config error")
    func organizationErrors() async throws {
        let (factory, _) = makeFactory([Self.rejected])
        let source = factory.make(for: runner(.organization(login: "octo")))
        await #expect(throws: TartBackendError.scaleSetAuthRejected) {
            try await source.run(demand.context)
        }
        #expect(!TartBackend.isTransient(TartBackendError.scaleSetAuthRejected))
        #expect(api.conditionalFetches.isEmpty)
    }

    @Test("other setup failures do not fall back")
    func otherFailureNoFallback() async throws {
        let (factory, _) = makeFactory([.json("", status: 502)])
        let source = factory.make(for: runner(.repository(fullName: "octo/ghast")))
        await #expect(throws: ScaleSetError.self) { try await source.run(demand.context) }
        #expect(api.conditionalFetches.isEmpty)
    }

    @Test("an accepted token uses the scale set")
    func usesScaleSet() async throws {
        let (factory, transport) = makeFactory([
            ScaleSetReplies.connection(exp: clock.now().addingTimeInterval(3600)),
            ScaleSetReplies.list([9]), ScaleSetReplies.session(assigned: 1),
        ])
        let source = factory.make(for: runner(.repository(fullName: "octo/ghast")))
        _ = try? await source.run(demand.context)
        #expect(demand.values == [1])
        #expect(await transport.requests.contains { $0.url?.path.hasSuffix("/runnerscalesets/9/sessions") == true })
        #expect(api.conditionalFetches.isEmpty)
    }

    @Test("an organization runner's scale set lives in its named group")
    func organizationGroup() async throws {
        api.mockRunnerGroups = [
            GitHubRunnerGroup(id: 1, name: "Default", isDefault: true),
            GitHubRunnerGroup(id: 7, name: "Macs", isDefault: false),
        ]
        var org = runner(.organization(login: "octo"))
        org.runnerGroup = "macs"
        let (factory, transport) = makeFactory([
            ScaleSetReplies.connection(exp: clock.now().addingTimeInterval(3600)), ScaleSetReplies.list([9]),
        ])
        _ = try? await factory.make(for: org).run(demand.context)
        #expect(await transport.requests[1].url?.query?.contains("runnerGroupId=7") == true)
    }

    @Test("once the scale set is set up, any run failure is one to retry, never a config error", arguments: [
        [FakeTransport.Reply.json("", status: 404)],
        [.json("", status: 401), .json("", status: 401)],
    ])
    func failuresAfterSetupAreTransient(failure: [FakeTransport.Reply]) async throws {
        let (factory, _) = makeFactory([
            ScaleSetReplies.connection(exp: clock.now().addingTimeInterval(3600)),
            ScaleSetReplies.list([9]), ScaleSetReplies.session(),
        ] + failure + [ScaleSetReplies.noContent])
        let source = factory.make(for: runner(.organization(login: "octo")))
        do {
            try await source.run(demand.context)
            Issue.record("run should fail")
        } catch {
            #expect(TartBackend.isTransient(error), "\(error)")
        }
    }

    @Test("a scale set that went missing is found again by the next run")
    func missingSetIsFoundAgain() async throws {
        let (factory, transport) = makeFactory([
            ScaleSetReplies.connection(exp: clock.now().addingTimeInterval(3600)),
            ScaleSetReplies.list([9]), ScaleSetReplies.session(), .json("", status: 404), ScaleSetReplies.noContent,
            ScaleSetReplies.list([12]), ScaleSetReplies.session(assigned: 2), .hang,
        ])
        let source = factory.make(for: runner(.repository(fullName: "octo/ghast")))
        _ = try? await source.run(demand.context)
        let recorder = demand
        let task = Task { try await source.run(recorder.context) }
        for _ in 0..<10_000 where !demand.values.contains(2) { await Task.yield() }
        task.cancel()
        _ = await task.result

        #expect(demand.values.contains(2))
        #expect(await transport.requests.contains { $0.url?.path.hasSuffix("/runnerscalesets/12/sessions") == true })
    }

    @Test("Remove on a runner whose token scale sets refuse has no scale set to delete")
    func deleteRemoteWhenRefused() async throws {
        let (factory, transport) = makeFactory([Self.rejected])
        let source = factory.make(for: runner(.repository(fullName: "octo/ghast")))
        try await source.deleteRemote()
        #expect(!(await transport.requests).contains { $0.httpMethod == "DELETE" })
    }

    @Test("a JIT config that fails after setup is one to retry, and a missing set is found again for the next")
    func jitFailureAfterSetup() async throws {
        let (factory, transport) = makeFactory([
            ScaleSetReplies.connection(exp: clock.now().addingTimeInterval(3600)),
            ScaleSetReplies.list([9]), .json("", status: 404),
            ScaleSetReplies.list([12]), ScaleSetReplies.jit(id: 77),
        ])
        let source = factory.make(for: runner(.organization(login: "octo")))
        do {
            _ = try await source.jitConfig(runnerName: "mac-vm-a1b2c3", workFolder: "_work")
            Issue.record("jitConfig should fail")
        } catch {
            #expect(TartBackend.isTransient(error), "\(error)")
        }

        let jit = try await source.jitConfig(runnerName: "mac-vm-d4e5f6", workFolder: "_work")
        #expect(jit.runnerID == 77)
        #expect(await transport.requests.last?.url?.path.hasSuffix("/runnerscalesets/12/generatejitconfig") == true)
    }
}
