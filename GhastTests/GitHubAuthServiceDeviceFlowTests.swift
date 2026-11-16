import Testing
import Observation
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

/// Poll calls suspend until the test resolves them, ignoring cancellation, so a test
/// can make an abandoned attempt fail *after* a newer one has started.
actor ControlledDeviceFlowClient: DeviceFlowClienting {
    private var pending: [CheckedContinuation<String, Error>] = []

    var pendingCount: Int { pending.count }

    func requestCode(scopes: [String]) async throws -> DeviceCode { FakeDeviceFlowClient.code }

    func pollForToken(_ code: DeviceCode) async throws -> String {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func resolve(call index: Int, with result: Result<String, Error>) {
        pending[index].resume(with: result)
    }
}

/// One-shot async latch for pausing a closure mid-flight.
actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class TokenUseLog {
    private(set) var tokens: [String] = []
    func use(_ token: String) { tokens.append(token) }
}

/// Records every `signInState` the service publishes, via a re-arming observation.
@MainActor
final class StateLog {
    private(set) var states: [SignInState]
    private let service: GitHubAuthService

    init(_ service: GitHubAuthService) {
        self.service = service
        states = [service.signInState]
        track()
    }

    private func track() {
        withObservationTracking {
            _ = service.signInState
        } onChange: { [weak self] in
            // onChange runs before the new value lands; read it after the mutation completes.
            Task { @MainActor [weak self] in self?.record() }
        }
    }

    private func record() {
        states.append(service.signInState)
        track()
    }

    /// Lets queued recordings run, so `states` reflects every change made so far.
    func flush() async {
        await Task.yield()
    }
}

@MainActor
@Suite struct GitHubAuthServiceDeviceFlowTests {
    static let user = GitHubUser(id: 1, login: "octocat", avatarURL: "", name: nil, email: nil)
    static let allScopes: Set<String> = ["repo", "user:email", "admin:org"]
    static let authenticated = AuthenticatedUser(user: user, grantedScopes: allScopes)

    func makeService(
        _ client: any DeviceFlowClienting,
        store: InMemoryTokenStore = InMemoryTokenStore(),
        used: TokenUseLog? = nil,
        fetchUser: @escaping @MainActor (String) async throws -> AuthenticatedUser = { _ in GitHubAuthServiceDeviceFlowTests.authenticated }
    ) -> GitHubAuthService {
        let used = used ?? TokenUseLog()
        return GitHubAuthService(apiService: MockGitHubAPIService(), deviceFlow: client, tokenStore: store, fetchUser: fetchUser, useToken: { used.use($0) })
    }

    /// Yields until the condition holds; bounded so a broken test fails instead of hanging.
    func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
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
        await log.flush()

        #expect(log.states == [.idle, .awaitingUser(FakeDeviceFlowClient.code), .signedIn])
        #expect(service.isAuthenticated)
        #expect(service.currentUser?.login == "octocat")
        #expect(await client.requestedScopes == [["repo", "user:email", "admin:org"]])
    }

    @Test func signInPersistsTokenAndHandsItToAPI() async {
        let store = InMemoryTokenStore()
        let used = TokenUseLog()
        let service = makeService(FakeDeviceFlowClient(polls: [.token("gho_abc")]), store: store, used: used)

        await service.signIn()

        #expect(store.writes == ["gho_abc"])
        #expect(used.tokens == ["gho_abc"])
    }

    @Test func storeWriteFailureBecomesFailedStorageState() async {
        let store = InMemoryTokenStore()
        store.writeError = TokenStoreError.keychain(errSecInteractionNotAllowed)
        let used = TokenUseLog()
        let service = makeService(FakeDeviceFlowClient(polls: [.token("gho_abc")]), store: store, used: used)

        await service.signIn()

        guard case .failed(.storage) = service.signInState else {
            Issue.record("expected failed(.storage), got \(service.signInState)")
            return
        }
        #expect(!service.isAuthenticated)
        #expect(service.currentUser == nil)
        #expect(used.tokens.isEmpty)
    }

    @Test func signOutDeletesStoredToken() async {
        let store = InMemoryTokenStore(token: "gho_abc")
        let service = makeService(FakeDeviceFlowClient(polls: []), store: store)

        service.signOut()

        #expect(store.deleteCount == 1)
        #expect(store.token == nil)
    }

    @Test func tokenIsHandedToCompletionStep() async {
        var received: String?
        let service = makeService(FakeDeviceFlowClient(polls: [.token("gho_abc")])) { token in
            received = token
            return Self.authenticated
        }

        await service.signIn()

        #expect(received == "gho_abc")
    }

    // MARK: admin:org scope upgrade

    @Test func requestsAdminOrgScope() {
        #expect(GitHubAuthService.scopes == ["repo", "user:email", "admin:org"])
    }

    /// Stored token "old" lacks `admin:org` unless `oldScopes` says otherwise; any other token has every scope.
    func makeStoredTokenService(
        oldScopes: Set<String>?,
        polls: [FakeDeviceFlowClient.Poll] = [],
        store: InMemoryTokenStore = InMemoryTokenStore(token: "old")
    ) -> GitHubAuthService {
        makeService(FakeDeviceFlowClient(polls: polls), store: store) { token in
            AuthenticatedUser(user: Self.user, grantedScopes: token == "old" ? oldScopes : Self.allScopes)
        }
    }

    @Test func storedTokenWithAdminOrgNeedsNoUpgrade() async {
        let service = makeStoredTokenService(oldScopes: Self.allScopes)

        await service.checkExistingAuth()

        #expect(service.isAuthenticated)
        #expect(!service.needsScopeUpgrade)
    }

    @Test func storedTokenWithoutAdminOrgNeedsUpgradeButStaysSignedIn() async {
        let store = InMemoryTokenStore(token: "old")
        let used = TokenUseLog()
        let service = makeService(FakeDeviceFlowClient(polls: []), store: store, used: used) { _ in
            AuthenticatedUser(user: Self.user, grantedScopes: ["repo", "user:email"])
        }

        await service.checkExistingAuth()

        #expect(service.needsScopeUpgrade)
        #expect(service.isAuthenticated)
        #expect(store.token == "old")
        #expect(store.deleteCount == 0)
        #expect(used.tokens == ["old"])
    }

    @Test func missingScopesHeaderCountsAsLackingAdminOrg() async {
        let service = makeStoredTokenService(oldScopes: nil)

        await service.checkExistingAuth()

        #expect(service.needsScopeUpgrade)
        #expect(service.isAuthenticated)
    }

    @Test func successfulReSignInClearsScopeUpgrade() async {
        let store = InMemoryTokenStore(token: "old")
        let service = makeStoredTokenService(oldScopes: ["repo"], polls: [.token("new")], store: store)
        await service.checkExistingAuth()
        #expect(service.needsScopeUpgrade)

        await service.signIn()

        #expect(!service.needsScopeUpgrade)
        #expect(store.token == "new")
    }

    @Test func failedReSignInKeepsOldTokenAndFlag() async {
        let store = InMemoryTokenStore(token: "old")
        let service = makeStoredTokenService(oldScopes: ["repo"], polls: [.failure(.denied)], store: store)
        await service.checkExistingAuth()

        await service.signIn()

        #expect(service.signInState == .failed(.denied))
        #expect(service.needsScopeUpgrade)
        #expect(service.isAuthenticated)
        #expect(store.token == "old")
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

    @Test func abandonedAttemptFailingLateDoesNotOverwriteNewAttempt() async {
        let client = ControlledDeviceFlowClient()
        let service = makeService(client)

        let first = Task { await service.signIn() }
        await waitUntil { await client.pendingCount == 1 }
        service.cancelSignIn()
        let second = Task { await service.signIn() }
        await waitUntil { await client.pendingCount == 2 }

        await client.resolve(call: 0, with: .failure(DeviceFlowError.network("late")))
        await first.value

        #expect(service.signInState == .awaitingUser(FakeDeviceFlowClient.code))

        await client.resolve(call: 1, with: .success("gho_new"))
        await second.value
        #expect(service.signInState == .signedIn)
    }

    @Test func cancelDuringUserFetchStoresNoToken() async {
        let gate = Gate()
        let store = InMemoryTokenStore()
        let service = makeService(FakeDeviceFlowClient(polls: [.token("gho_abc")]), store: store) { _ in
            await gate.wait()
            return Self.authenticated
        }

        let signIn = Task { await service.signIn() }
        await waitUntil { await gate.isWaiting }
        service.cancelSignIn()
        await gate.open()
        await signIn.value

        #expect(store.writes.isEmpty)
        #expect(service.signInState == .idle)
        #expect(!service.isAuthenticated)
        #expect(service.currentUser == nil)
    }

    @Test func abandonedAttemptFailingInUserFetchLeavesNewerSignInIntact() async {
        let gate = Gate()
        let store = InMemoryTokenStore()
        let service = makeService(
            FakeDeviceFlowClient(polls: [.token("old"), .token("new")]),
            store: store
        ) { token in
            if token == "old" {
                await gate.wait()
                throw URLError(.notConnectedToInternet)
            }
            return Self.authenticated
        }

        let first = Task { await service.signIn() }
        await waitUntil { await gate.isWaiting }
        service.cancelSignIn()
        await service.signIn()
        #expect(service.signInState == .signedIn)

        await gate.open()
        await first.value

        #expect(service.signInState == .signedIn)
        #expect(store.writes == ["new"])
        #expect(service.isAuthenticated)
    }

    @Test func urlSessionCancellationIsNotAFailure() async {
        let service = makeService(FakeDeviceFlowClient(polls: [.token("gho_abc")])) { _ in
            throw URLError(.cancelled)
        }

        await service.signIn()

        #expect(service.signInState == .idle)
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
