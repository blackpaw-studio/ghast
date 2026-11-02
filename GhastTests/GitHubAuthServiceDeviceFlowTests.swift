import Testing
import Combine
import Foundation
@testable import Ghast

/// Scripted `DeviceFlowClienting`. Each poll call consumes the next script entry.
actor FakeDeviceFlowClient: DeviceFlowClienting {
    enum Poll: Sendable {
        case token(String)
        case failure(DeviceFlowError)
        /// Suspends until the task is cancelled, like a real poll waiting on the user.
        case hang
    }

    static let code = DeviceCode(
        deviceCode: "dev123",
        userCode: "WDJB-MJHT",
        verificationURI: URL(string: "https://github.com/login/device")!,
        expiresIn: 900,
        interval: 5
    )

    private let codeFailure: DeviceFlowError?
    private var polls: [Poll]
    private(set) var requestCount = 0
    private(set) var requestedScopes: [[String]] = []

    init(codeFailure: DeviceFlowError? = nil, polls: [Poll]) {
        self.codeFailure = codeFailure
        self.polls = polls
    }

    func requestCode(scopes: [String]) async throws -> DeviceCode {
        requestCount += 1
        requestedScopes.append(scopes)
        if let codeFailure { throw codeFailure }
        return Self.code
    }

    func pollForToken(_ code: DeviceCode) async throws -> String {
        guard !polls.isEmpty else { throw DeviceFlowError.unexpected("script exhausted") }
        switch polls.removeFirst() {
        case let .token(token): return token
        case let .failure(error): throw error
        case .hang:
            while true {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }
}

@MainActor
final class StateLog {
    private(set) var states: [SignInState] = []
    private var cancellable: AnyCancellable?

    init(_ service: GitHubAuthService) {
        cancellable = service.$signInState.sink { [weak self] in self?.states.append($0) }
    }
}

@MainActor
@Suite struct GitHubAuthServiceDeviceFlowTests {
    static let user = GitHubUser(id: 1, login: "octocat", avatarURL: "", name: nil, email: nil)

    func makeService(
        _ client: FakeDeviceFlowClient,
        completeSignIn: @escaping @MainActor (String) async throws -> GitHubUser = { _ in GitHubAuthServiceDeviceFlowTests.user }
    ) -> GitHubAuthService {
        GitHubAuthService(deviceFlow: client, completeSignIn: completeSignIn)
    }

    /// Yields until the condition holds; bounded so a broken test fails instead of hanging.
    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 where !condition() { await Task.yield() }
    }

    @Test func startsIdle() {
        let service = makeService(FakeDeviceFlowClient(polls: []))
        #expect(service.signInState == .idle)
        #expect(!service.isLoading)
        #expect(!service.isAuthenticating)
    }

    @Test func signInMovesIdleToAwaitingUserToSignedIn() async {
        let client = FakeDeviceFlowClient(polls: [.token("gho_abc")])
        let service = makeService(client)
        let log = StateLog(service)

        await service.signIn()

        #expect(log.states == [.idle, .awaitingUser(FakeDeviceFlowClient.code), .signedIn])
        #expect(service.isAuthenticated)
        #expect(service.currentUser?.login == "octocat")
        #expect(await client.requestedScopes == [["repo", "user:email"]])
    }

    @Test func tokenIsHandedToCompletionStep() async {
        var received: String?
        let service = makeService(FakeDeviceFlowClient(polls: [.token("gho_abc")])) { token in
            received = token
            return Self.user
        }

        await service.signIn()

        #expect(received == "gho_abc")
    }

    @Test(arguments: [DeviceFlowError.expired, .denied, .disabled, .network("offline"), .unexpected("boom")])
    func pollFailureBecomesFailedState(error: DeviceFlowError) async {
        let service = makeService(FakeDeviceFlowClient(polls: [.failure(error)]))

        await service.signIn()

        #expect(service.signInState == .failed(error))
        #expect(!service.isAuthenticated)
    }

    @Test func codeRequestFailureBecomesFailedState() async {
        let service = makeService(FakeDeviceFlowClient(codeFailure: .disabled, polls: []))

        await service.signIn()

        #expect(service.signInState == .failed(.disabled))
    }

    @Test func userFetchFailureBecomesFailedNetworkState() async {
        let service = makeService(FakeDeviceFlowClient(polls: [.token("gho_abc")])) { _ in
            throw URLError(.notConnectedToInternet)
        }

        await service.signIn()

        guard case .failed(.network) = service.signInState else {
            Issue.record("expected failed(.network), got \(service.signInState)")
            return
        }
        #expect(!service.isAuthenticated)
    }

    @Test func cancelWhileAwaitingReturnsToIdle() async {
        let service = makeService(FakeDeviceFlowClient(polls: [.hang]))
        let signIn = Task { await service.signIn() }
        await waitUntil { service.signInState == .awaitingUser(FakeDeviceFlowClient.code) }
        #expect(service.signInState == .awaitingUser(FakeDeviceFlowClient.code))
        #expect(service.isAuthenticating)

        service.cancelSignIn()
        await signIn.value

        #expect(service.signInState == .idle)
        #expect(!service.isAuthenticating)
    }

    @Test func tryAgainAfterFailureRequestsNewCode() async {
        let client = FakeDeviceFlowClient(polls: [.failure(.expired), .token("gho_abc")])
        let service = makeService(client)

        await service.signIn()
        #expect(service.signInState == .failed(.expired))

        await service.signIn()

        #expect(service.signInState == .signedIn)
        #expect(await client.requestCount == 2)
    }
}
