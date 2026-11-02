# Spec: GitHub Device Flow sign-in

Date: 2026-11-01 · Status: draft for approval

## Problem
Sign-in uses the OAuth web flow and exchanges the code with a client secret hardcoded in the app (`GitHubAuthService.swift:222`, plus test files). Anyone with the binary or the repo history has it. A desktop app cannot keep a secret, so the fix is a flow that doesn't need one.

## Decision
Replace the web callback flow with GitHub's OAuth Device Flow (RFC 8628). It needs only the client ID. Same OAuth app (`Ov23liLVIllxzZoRYwAN`), same scopes (`repo user:email`), same Keychain token storage. Tokens stay non-expiring (OAuth app default), so there is no refresh handling.

Rejected alternatives:
- Web flow with PKCE: GitHub OAuth apps still expect the secret at token exchange.
- Converting to a GitHub App: bigger change to the permissions model; not needed to fix the leak.

## User experience
1. The user clicks **Sign in with GitHub** in the login view.
2. The app requests a device code. The login view shows the 8-character user code (large, monospaced, selectable) and copies it to the clipboard. It also has an **Open GitHub** button, which opens `verification_uri` in the default browser, plus **Copy code** and **Cancel** buttons.
3. The browser opens automatically once, right when the code is shown.
4. The app polls in the background. On success, it shows the dashboard, same as today.
5. Failure states, each with a plain message and a **Try again** button:
   - The code expired after `expires_in` (default 15 minutes).
   - The user denied access on GitHub.
   - Network error.
   - Device flow is disabled on the app (`device_flow_disabled`). This one is a developer-facing message.

## Design
- **`DeviceFlowClient`**: a new value type that is `Sendable` and independent of the UI. It has two operations:
  - `requestCode(scopes:) -> DeviceCode`
  - `pollForToken(_ code: DeviceCode) async throws(DeviceFlowError) -> String`
  - It takes two injected dependencies:
    - an `HTTPTransport` (a protocol over URLSession) for the network calls
    - a `Sleeper` (an async sleep closure or protocol) for the polling waits
  - It posts form- or JSON-encoded requests with `Accept: application/json`.
- **Polling rules:**
  - Wait `interval` seconds before each poll.
  - `authorization_pending`: keep polling.
  - `slow_down`: increase the interval by 5 seconds, or use the server's `interval` if one is returned.
  - `expired_token`, or elapsed time past `expires_in`: throw `.expired`.
  - `access_denied`: throw `.denied`.
  - `device_flow_disabled`: throw `.disabled`.
  - Transport failure: throw `.network(String)`.
  - Any other error code or a malformed body: throw `.unexpected(String)`.
  - Cancelling the task stops polling promptly. It throws `CancellationError` and makes no further requests.
- **`GitHubAuthService`**:
  - Uses `DeviceFlowClient`, injected through `init` with a production default.
  - Publishes one sign-in state for the view: `idle`, `awaitingUser(DeviceCode)`, `failed(DeviceFlowError)`, `signedIn`.
  - `signIn()` drives the flow, and `cancelSignIn()` cancels it.
  - After it gets a token, it keeps the existing behaviour: store it in Keychain, set it on the API service, fetch the user.
  - The 60-second timeout task group goes away, because the expiry comes from the server.
- **Remove:**
  - the client secret
  - `buildAuthURL` and `extractCode`
  - `exchangeCodeForToken`'s secret exchange
  - `debugTestOAuthCallback`
  - the `.oauthCallback` notification and its observers in AppDelegate and `onOpenURL`
  - the `ASWebAuthenticationPresentationContextProviding` extension
  - the `ghast://auth/callback` handling
- **URL scheme:** drop the `ghast://` scheme from `project.yml` and Info.plist only if nothing else uses it. If something does, keep the scheme and remove only the auth route.
- **Docs:** update `CLAUDE.md` and `README` to remove the redirect-URI and callback-testing instructions.

## Testing
- Unit tests for `DeviceFlowClient` use a fake transport and a recording sleeper, so nothing really sleeps or hits the network. Cases:
  - success after N pending responses
  - `slow_down` increases the interval
  - expiry
  - denial
  - disabled
  - malformed response
  - cancellation stops polling
  - requests carry `client_id`, `device_code` and the grant-type URN, and never a `client_secret`
- `GitHubAuthService` state transitions are tested with a fake client.
- Delete or rewrite the OAuth tests that rely on the callback or the secret: `OAuthFlowDebugTest`, `MockOAuthTests`, and any `oauthCallback` tests.
- Add a test or check that fails if the string `client_secret` appears anywhere under `Ghast/`.
- New tests use Swift Testing (`@Test`). Existing XCTest tests stay XCTest.
- Login-view snapshots cover `awaitingUser` and `failed`.
- Manual check: sign in for real on the built app.

## Owner actions (Evan)
1. Before testing: in the GitHub OAuth app settings, tick **Enable Device Flow**.
2. After this ships and the release is out: delete the client secret in the OAuth app settings, so the leaked value is dead. No git-history rewrite is needed once the secret is revoked.

## Out of scope
Swift 6 / `@Observable` migration, replacing KeychainAccess, other singletons. Those are phases 4–5. The token is still read from `GitHubAPIService.shared` as today.
