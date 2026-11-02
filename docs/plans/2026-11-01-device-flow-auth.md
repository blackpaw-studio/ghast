# Plan: GitHub Device Flow sign-in

Spec: `docs/specs/2026-11-01-device-flow-auth.md`. If this plan and the spec disagree, the spec wins. Branch off `main` after phase 1 (`modernize/phase1-green`) has merged. Run `xcodegen` before each step's test command.

## Steps
1. **`DeviceFlowClient` types.** Create `Ghast/Services/DeviceFlow/DeviceFlowClient.swift` with:
   - `DeviceCode`: Sendable and Equatable; fields `deviceCode`, `userCode`, `verificationURI`, `expiresIn`, `interval`.
   - `DeviceFlowError`: cases `.expired`, `.denied`, `.disabled`, `.network(String)`, `.unexpected(String)`; Equatable.
   - `protocol HTTPTransport: Sendable { func send(_: URLRequest) async throws -> (Data, HTTPURLResponse) }`, plus a `URLSessionTransport` implementation.
   - `Sleeper = @Sendable (Duration) async throws -> Void`; the default calls `Task.sleep`.
   - Client ID `Ov23liLVIllxzZoRYwAN`.
   - Failing test: `GhastTests/DeviceFlowClientTests.swift`, an `@Suite` with `@Test requestCodePostsClientIdAndScopes`. A `FakeTransport` records the request. Check that it is a POST to `https://github.com/login/device/code` with `Accept: application/json`, `client_id` and `scope=repo user:email`, and that the response decodes to a `DeviceCode`.
   - Verify: `xcodebuild test -project Ghast.xcodeproj -scheme Ghast -only-testing:GhastTests/DeviceFlowClientTests`
2. **`pollForToken` polling rules.** Each poll is a POST to `/login/oauth/access_token` with `client_id`, `device_code` and `grant_type=urn:ietf:params:oauth:grant-type:device_code`. Measure elapsed time as the sum of the sleeper's waits, so tests need no real clock. Add one failing `@Test` at a time:
   - `succeedsAfterNPending`
   - `slowDownAddsFiveSeconds`
   - `slowDownUsesServerInterval`
   - `expiredTokenThrowsExpired`
   - `elapsedPastExpiresInThrowsExpired`
   - `accessDeniedThrowsDenied`
   - `deviceFlowDisabledThrowsDisabled`
   - `transportErrorThrowsNetwork`
   - `unknownErrorOrMalformedThrowsUnexpected`
   - `cancellationStopsPolling`: the sleeper throws `CancellationError`; check that no further requests are made.
   - `noRequestCarriesClientSecret`
3. **`GitHubAuthService` on device flow.**
   - Add `enum SignInState: Equatable { idle, awaitingUser(DeviceCode), failed(DeviceFlowError), signedIn }` and publish it as `@Published var signInState`.
   - Change the initializer to `init(deviceFlow: any DeviceFlowClienting = DeviceFlowClient())`.
   - `signIn()` stores its `Task`; `cancelSignIn()` cancels it and returns to `idle`.
   - After a token arrives: save it to Keychain, call `GitHubAPIService.shared.setAccessToken`, call `fetchCurrentUser`, then set `signedIn`. This logic moves over from the old `exchangeCodeForToken`.
   - Delete the 60-second task group.
   - Derive the existing `isLoading` and `isAuthenticating` from `signInState`, because other views and the mock still read them.
   - Add `cancelSignIn()` to `GitHubAuthServiceProtocol`, remove `debugTestOAuthCallback`, and update `GhastTests/Mocks/MockGitHubAuthService.swift`.
   - Failing tests: `GhastTests/GitHubAuthServiceDeviceFlowTests.swift`, using a `FakeDeviceFlowClient`:
     - `idle` → `awaitingUser` → `signedIn`
     - each error leads to `failed(error)`
     - cancel returns to `idle`
     - **Try again** after a failure requests a new code
4. **Login view (`Ghast/Views/WelcomeView.swift`)**, driven by `signInState`.
   - `awaitingUser`: the code shown large, monospaced and selectable, with **Open GitHub**, **Copy code** and **Cancel** buttons.
   - When the state first enters `awaitingUser`, use `.onChange` to copy the code to the pasteboard once and call `openURL(verificationURI)` once.
   - `failed`: show a message for each error (the `.disabled` one is aimed at developers) and a **Try again** button.
   - Remove the local `isSigningIn` and the debug `print` calls.
   - Snapshot tests (XCTest, matching the existing file): add `testWelcomeViewAwaitingUser` and `testWelcomeViewFailed` to `WelcomeViewSnapshotTests.swift`. Record them, then switch recording back off.
5. **Remove the callback plumbing and the client secret** (exact list below).
   - Add `GhastTests/NoClientSecretTests.swift`: a `@Test` that walks `Ghast/` (path derived from `#filePath`) and expects no file to contain `client_secret`. It should fail before this step and pass after it.
   - Also verify that `grep -rn "client_secret\|oauthCallback\|ghast://" Ghast GhastTests project.yml` finds nothing.
6. **Docs.** In `CLAUDE.md`, remove the text about the redirect URI, the URL scheme, dual URL handling and callback testing. In `README.md`, mention device flow.
7. **Integration gate.** Check the load, then run `heavy xcodebuild test -project Ghast.xcodeproj -scheme Ghast` in the background. Then hand off for a manual sign-in on the built app (owner action 1) and dispatch the review.

## Delete or rewrite
The `ghast://` scheme is used only for the auth callback, so it can be dropped entirely:
- `GhastApp.swift:13-21` (the `.onOpenURL` block), `:29` (`.handlesExternalEvents(matching: "ghast")`), `:66-72` (the `NSAppleEventManager` registration), `:92-112` (`handleGetURLEvent`), and `:205-207` (`Notification.Name.oauthCallback`).
- `project.yml:35-37` (`CFBundleURLTypes`) and `Ghast/Info.plist:23-34`. xcodegen regenerates `Info.plist`; commit the regenerated file.

In `GitHubAuthService.swift`:
- Remove the secret (`:222`), `redirectURI`, `authSession` and `import AuthenticationServices`.
- Remove `debugTestOAuthCallback`, `performOAuthFlow`, `buildAuthURL` and `extractCode`.
- Remove the secret request in `exchangeCodeForToken`.
- Remove the `ASWebAuthenticationPresentationContextProviding` extension and the `isRunningTests` guard that stops the browser opening.

In `GitHubAuthServiceProtocol.swift:17`, remove `debugTestOAuthCallback`.

Delete these test files: `GhastTests/OAuthFlowDebugTest.swift`, `GhastTests/MockOAuthTests.swift` and `GhastTests/AppDelegateTests.swift`. Confirm first that `AppDelegateTests.swift` holds only callback tests.

Remove only the callback and secret cases from:
- `OAuthFlowIntegrationTests.swift:45-100`
- `IntegrationTests.swift:30-135`
- `AuthenticationStateTest.swift:75-110`
- `GitHubAuthServiceTests.swift:92-225`
- `GhastAppTests.swift:50-155`
- `Mocks/MockGitHubAuthService.swift:27-29`

The line numbers are from before phase 1, so re-check them after rebasing.

## Risks
- **Mixed test frameworks:** the new Swift Testing suites live in an XCTest bundle next to `@MainActor` classes. In Swift 5 mode, Sendable problems show up only as warnings.
- **Manual sign-in needs owner action 1:** it fails with `device_flow_disabled` until Evan enables Device Flow on the OAuth app.
- **The leaked secret stays valid until revoked:** it remains in git history and in shipped binaries until Evan revokes it (owner action 2).
