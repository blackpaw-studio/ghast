# Phase 4 — Dependency modernization: implementation plan

Spec: `docs/specs/2026-11-02-phase4-dependencies.md` (spec wins on conflict). Branch: `modernize/phase4-deps`.

## Conventions
- Run `xcodegen` after any step that adds/deletes files or edits `project.yml`.
- Targeted tests: `T="xcodebuild test -project Ghast.xcodeproj -scheme Ghast -destination platform=macOS"`, then `$T -only-testing:GhastTests/<Suite>`. Run directly; if a run exceeds ~2 min (cold build after a package change), rerun as `heavy $T …` in the background.
- Full builds, full suites, package-graph changes: `heavy …` with Bash `run_in_background`. Check `uptime` first; above ~30 run targeted checks only and defer to step 8.
- One commit per step, emoji prefix. Commit `Ghast.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` whenever it changes (tracked).
- Review routing: token-storage steps (2, 3, 5) → `review.security`; rest → `review`.

## Step 1 — Share the HTTP transport (♻️, pure move, TDD exception)
- Move `HTTPTransport` + `URLSessionTransport` from `Ghast/Services/DeviceFlow/DeviceFlowClient.swift` to new `Ghast/Services/HTTP/HTTPTransport.swift`.
- Move the `FakeTransport` actor from `GhastTests/DeviceFlowClientTests.swift` to `GhastTests/Mocks/FakeTransport.swift`. Leave `formFields` and `RecordingSleeper` in place.
- Verify: `xcodegen && $T -only-testing:GhastTests/DeviceFlowClientTests -only-testing:GhastTests/DeviceFlowPollingTests`
- Commit: `♻️ Move HTTPTransport and FakeTransport to shared locations`

## Step 2 — `TokenStore` + `KeychainTokenStore` (✨, test-first)
Tests first: new `GhastTests/KeychainTokenStoreTests.swift` (Swift Testing; tests run in parallel, so each uses service `"net.evancoleman.ghast.tests.\(UUID())"` with `defer { try? store.delete() }`).
- Behavior: missing item reads `nil`; write/read round-trips (parameterized: `gho_abc`, `""`, 1004-char token, special characters); second write overwrites; delete removes; deleting a missing item is a no-op.
- Compatibility (while KeychainAccess is still linked):
  - Store reads a token written by `Keychain(service:).accessibility(.afterFirstUnlock).set(_, key: "github_token")`.
  - KeychainAccess reads a token written by the store.
  - After a KeychainAccess write of `old`, `store.write("new")` → both read `new`; `SecItemCopyMatching` with `kSecMatchLimitAll` finds exactly one item.
  - Attribute parity: KeychainAccess item (service A) vs store item (service B) fetched with `kSecReturnAttributes` — `class`, `acct`, `pdmn`, `sync`, and absence of `agrp` equal. KeychainAccess is ground truth.

Implementation: new `Ghast/Services/TokenStore/TokenStore.swift`.
- `protocol TokenStore { func read() throws -> String?; func write(_ token: String) throws; func delete() throws }`
- `enum TokenStoreError: Error, Equatable, CustomStringConvertible { case keychain(OSStatus), invalidData }` (description via `SecCopyErrorMessageString`).
- `struct KeychainTokenStore: TokenStore` (defaults: service `net.evancoleman.ghast`, account `github_token`), mirroring KeychainAccess 4.2.2:
  - Base query: `kSecClassGenericPassword`, service, account, `kSecAttrSynchronizable: kSecAttrSynchronizableAny`.
  - `read`: base + `kSecMatchLimitOne` + `kSecReturnData`; `errSecItemNotFound` → `nil`; non-UTF-8 → `.invalidData`.
  - `write`: `SecItemUpdate(base, [data, kSecAttrAccessible: AfterFirstUnlock, sync: false])`; on `errSecItemNotFound` → `SecItemAdd` (class, service, account, data, AfterFirstUnlock, sync false).
  - `delete`: `SecItemDelete(base)`; `errSecItemNotFound` is success.
  - Never set `kSecUseDataProtectionKeychain` or `kSecAttrAccessGroup` (KeychainAccess sets neither; either would route to the data-protection keychain and orphan existing tokens).
- Verify: `xcodegen && $T -only-testing:GhastTests/KeychainTokenStoreTests`. Paste the passing compatibility test names into the commit body — the only run with both libraries linked.
- Commit: `✨ Add TokenStore with a KeychainAccess-compatible Keychain implementation`

## Step 3 — Inject `TokenStore` into `GitHubAuthService` (✨, test-first)
Tests first:
- New `GhastTests/Mocks/InMemoryTokenStore.swift`: final class with `token`, `writes: [String]`, `deleteCount`, `writeError: Error?`.
- `GitHubAuthServiceDeviceFlowTests.swift`: replace `CommitLog` with `InMemoryTokenStore`; `makeService` passes `tokenStore:` and `useToken:`; `commits.tokens` assertions → `store.writes`. New: `signInPersistsTokenAndHandsItToAPI` (`writes == ["gho_abc"]`, `useToken` gets the token); `storeWriteFailureBecomesFailedStorageState` (`.failed(.storage(_))`, `!isAuthenticated`, `currentUser == nil`, `useToken` never called); `signOutDeletesStoredToken`.
- `GitHubAuthServiceTests.swift`: drop `import KeychainAccess` and `mockKeychain`; build with `InMemoryTokenStore()` (today `testSignOut` deletes the developer's real `github_token`).

Implementation:
- `GitHubAuthService.init(deviceFlow:, tokenStore: any TokenStore = KeychainTokenStore(), fetchUser:, useToken: (@MainActor (String) -> Void)? = nil)` replaces `commitToken`; default `useToken` = `GitHubAPIService.shared.setAccessToken`.
- `runSignIn`: after the last `isCurrent` guard, `try tokenStore.write(token)` then `useToken`. Catch logs via `os.Logger(subsystem: "net.evancoleman.ghast", category: "auth")`; never log the token.
- `failure(for:)` maps `TokenStoreError` → `.storage(description)`. Add `case storage(String)` to `DeviceFlowError` (`DeviceFlowClient.swift`) and its `userMessage` in `Ghast/Views/DeviceFlowViews.swift`: "Couldn't save your sign-in to the Keychain (…). Try again."
- `signOut`: `try tokenStore.delete()`, log on failure. `checkExistingAuth`: `guard let token = try tokenStore.read()`, rest unchanged (incl. delete on failure).
- Remove `import KeychainAccess` and `import Alamofire` from `GitHubAuthService.swift`.
- Verify: `xcodegen && $T -only-testing:GhastTests/GitHubAuthServiceDeviceFlowTests -only-testing:GhastTests/GitHubAuthServiceTests`
- Commit: `✨ Inject TokenStore into GitHubAuthService and surface Keychain write failures`

## Step 4 — `GitHubAPIService` on `HTTPTransport` (♻️, test-first)
Tests first: new `GhastTests/GitHubAPIServiceRequestTests.swift` (Swift Testing, `FakeTransport`, stored token `tok`, repo `octo/ghast`).
- Every endpoint asserts method + URL, `Authorization: Bearer tok`, `Accept: application/json`, `X-GitHub-Api-Version: 2022-11-28`, and decoded value.
- One test per endpoint: `GET /user`; `fetchCurrentUser(token: "x")` sends `Bearer x`; `GET /user/repos` (query as dict `{type=all, sort=updated, direction=desc, page=1, per_page=100}`; pagination 100 then 1 → 2 requests, `page=2`, 101 results); `GET /repos/octo/ghast/actions/runners` unwraps `runners`; `GET /orgs/acme/actions/runners`; `POST …/runners/registration-token` (201); `POST …/runners/remove-token`; `DELETE …/runners/42` (204, empty body); `GET …/runners/downloads`.
- Errors: parameterized status 401 → `.unauthorized`, 404 → `.notFound`, 503 → `.serverError(503)`, 403/422 → `.httpStatus(code)`, all with `error.statusCode == code`; 200 with `not json` → `.decodingError`; transport throw → `.networkError`. `GitHubAPIError` isn't Equatable — use the `#expect(throws:)` closure form.

Implementation:
- `Ghast/Models/GitHubModels.swift`: add `case httpStatus(Int)` ("GitHub returned HTTP \(code)") and `var statusCode: Int?` (401, 404, serverError, httpStatus). Add a description assertion to `GitHubModelsTests`.
- `GitHubAPIService`: internal `init(transport: any HTTPTransport = URLSessionTransport())`; keep `static let shared = GitHubAPIService()`. Private helpers `makeRequest(method:path:query:token:)` → `send` (2xx check, status mapping) → `decode`. Delete `mapAFError` and `import Alamofire`.
- Delete `GhastTests/GitHubAPIServiceMockTests.swift` (assertion-free; holds `MockURLSession` and the Alamofire import).
- Deliberate header unification: every request sends `Accept` + API version; `Authorization` only when a token exists. (Today a tokenless service sends no headers and the explicit-token `/user` omits the version header.) `User-Agent` comes from URLSession's default — GitHub requires one.
- Cancellation: URLSession honors Task cancellation, so `.task`-driven fetches now throw when a view disappears. Views must not surface an error for cancellation (`CancellationError` or `URLError.cancelled`) — add a test for the mapping and guard the view error paths.
- Verify: `xcodegen && $T -only-testing:GhastTests/GitHubAPIServiceRequestTests -only-testing:GhastTests/GitHubModelsTests`
- Commit: `♻️ Move GitHubAPIService from Alamofire to HTTPTransport`

## Step 5 — Remove Alamofire and KeychainAccess (🔥)
1. Rewrite step 2's compatibility tests around a test helper `legacyWrite(token:service:)` that calls `SecItemAdd` with the exact KeychainAccess 4.2.2 dictionary (genp, svce, acct, `v_Data`, `pdmn = AfterFirstUnlock`, `sync = false`). Keep three: store reads legacy item; store write updates legacy item in place (one item after); attribute parity legacy vs store. Run them while KeychainAccess is still linked.
2. Delete `GhastTests/KeychainIntegrationTests.swift` (tests KeychainAccess itself, not app behavior).
3. `project.yml`: remove `KeychainAccess` and `Alamofire` from `packages:` and Ghast `dependencies:`. Update dependency/API-client lines in `CLAUDE.md`.
4. `xcodegen && xcodebuild -resolvePackageDependencies -project Ghast.xcodeproj -scheme Ghast`
5. `grep -rniE 'alamofire|keychainaccess' project.yml Ghast GhastTests Ghast.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` prints nothing.
6. `heavy xcodebuild build -project Ghast.xcodeproj -scheme Ghast` (background), then `$T -only-testing:GhastTests/KeychainTokenStoreTests`.
- Commit: `🔥 Remove Alamofire and KeychainAccess packages`

## Step 6 — Sparkle → 2.10.1 (⬆️)
- `project.yml`: Sparkle `from: "2.10.1"`; `xcodegen`; resolve. Package.resolved shows 2.10.1 (record in commit body if a newer 2.x resolves).
- `heavy` build in background; watch for errors/deprecations in `GhastApp.swift` (`SPUStandardUpdaterController`) and `Views/CheckForUpdatesView.swift`.
- Verify: `$T -only-testing:GhastTests/GhastAppTests`
- Commit: `⬆️ Bump Sparkle to 2.10.1`

## Step 7 — swift-snapshot-testing → 1.19.x (⬆️)
- `project.yml`: SnapshotTesting `from: "1.19.7"`; `xcodegen`; resolve. Commit any moved transitive pins.
- Run all `*SnapshotTests` + `SimpleSnapshotTest` on the build host with `heavy` (background). Refs stay 1x.
- If a snapshot fails, do not re-record — return the failure images to the orchestrator.
- Commit: `⬆️ Bump swift-snapshot-testing to 1.19.7`

## Step 8 — Integration gate
- Full suite: `heavy xcodebuild test -project Ghast.xcodeproj -scheme Ghast -destination platform=macOS` (background, after load check).
- Repeat the step 5 grep; report `main..HEAD` for review.
- Manual check for Evan: run `main` via `xcode-remote run` and sign in; then run this branch — it should open signed in. macOS may prompt to allow Ghast access to the "net.evancoleman.ghast" keychain item (ad-hoc Debug signatures change per build): click Allow; the prompt isn't a compatibility failure. Denying triggers the existing delete-on-failure path.

## Behavior changes for reviewers
- Decode failures: `.networkError(DecodingError)` → `.decodingError`.
- 403/422/429: `.networkError(AFError)` → `.httpStatus(code)`.
- `/user` content-type validation dropped; non-JSON 2xx fails as `.decodingError`.
- Cancellation now propagates to requests (see step 4).

## Proposed follow-ups (out of scope)
- Delete real-network tests in `GhastTests/GitHubAPIServiceTests.swift` (`*WithoutToken`, custom-token) — they hit api.github.com via `.shared`; step 4 covers them.
- `checkExistingAuth` deletes the stored token on any failure, incl. offline launch; with `statusCode` it could delete only on `.unauthorized`.
- `isRunningTests()` gate blocks testing the stored-auth path; injected `TokenStore` makes removing it possible.
