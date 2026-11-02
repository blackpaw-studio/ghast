# Phase 4 — Dependency modernization

Approved by Evan 2026-11-02.

## Goal
Drop Alamofire and KeychainAccess, bump remaining dependencies, and make the
GitHub API and token storage testable through injected seams.

## Scope

### 1. Networking: Alamofire → URLSession via `HTTPTransport`
- `GitHubAPIService` takes an `HTTPTransport` (the protocol `DeviceFlowClient`
  already uses; production `URLSessionTransport`) via `init`, with a production
  default so `.shared` keeps working.
- Behavior parity for all 8 endpoints (GET /user, repos, runners ×2, POST
  registration token, POST remove token, DELETE runner, GET runner
  applications): same URLs, query params, method, `Authorization: Bearer`,
  `Accept`, `X-GitHub-Api-Version: 2022-11-28`, 2xx validation, JSON decoding.
  Non-2xx surfaces a typed error that includes the status code.
- Tests (Swift Testing, fake transport): one per endpoint covering request
  shape + decoding, plus non-2xx and decode-failure cases.
- Remove `import Alamofire` everywhere and the Alamofire package.

### 2. Keychain: KeychainAccess → `TokenStore`
- `protocol TokenStore { read / write / delete }` with throwing semantics.
- `KeychainTokenStore`: thin Security.framework (`SecItem*`) implementation,
  generic password, service `net.evancoleman.ghast`, account `github_token`,
  `kSecAttrAccessibleAfterFirstUnlock`, not synchronizable, no access group —
  must read tokens written by the current KeychainAccess build.
- `GitHubAuthService` takes a `TokenStore` via `init` (production default).
  Write failures are no longer swallowed: logged and surfaced as sign-in failure.
- Auth tests use an in-memory store. One integration test round-trips the real
  Keychain under a test-only service and cleans up.
- Remove the KeychainAccess package and replace `KeychainIntegrationTests`
  usage of it.

### 3. Version bumps
- Sparkle → 2.10.1, swift-snapshot-testing → 1.19.7 (or latest 1.19.x).

### 4. Dead code removed as part of the swap
- Unused Alamofire imports, `MockURLSession` in `GitHubAPIServiceMockTests`,
  the unused test `Keychain` in `GitHubAuthServiceTests`.

## Out of scope
Removing `.shared` singletons, Swift 6 mode, `@Observable`, rate-limit
handling, status checks on avatar/tarball downloads, snapshot render scale.

## Acceptance
- Builds with no Alamofire/KeychainAccess in `project.yml` or resolved packages.
- Full test suite green (snapshot refs remain 1x; run on build host).
- Manual: an existing signed-in token from the pre-Phase-4 build still signs in
  after upgrading (Evan, via `xcode-remote run`).
