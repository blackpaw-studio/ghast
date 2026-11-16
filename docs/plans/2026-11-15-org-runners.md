# Org-level self-hosted runners — implementation plan

Spec: `docs/specs/2026-11-15-org-runners.md` (source of truth on conflict). Branch: `feat/org-runners`.

## Conventions
- `xcodegen` after any step that adds files.
- `T="xcodebuild test -project Ghast.xcodeproj -scheme Ghast -destination platform=macOS"`. Targeted suites run directly via `$T -only-testing:GhastTests/<Suite>`; the full suite only at step 12 as `heavy $T` (run_in_background), after checking `uptime`.
- New tests use Swift Testing; existing XCTest files edited in place. Snapshots recorded at 1x on this host with `TEST_RUNNER_SNAPSHOT_RECORD_MODE=true`, re-run without it to confirm green, then commit PNGs.
- Emoji-prefixed commits, each compiling. No new singletons — new things flow through `AppDependencies`/environment.
- Review severity bar: fix P0/P1 and anything a real user can hit (data loss in `localRunners`, wrong `--url`, 403 crashing/blanking a page).

## 1. `RunnerScope` value type (✨ test-first)
- Test first — new `GhastTests/RunnerScopeTests.swift`, parameterized over both cases: `apiPathPrefix` (`/repos/octo/ghast`, `/orgs/acme`), `configURL` (`https://github.com/octo/ghast`, `https://github.com/acme`), `displayName`, `isOrganization`; `RunnerScope(gitHubURL:)` maps `https://github.com/acme` → `.organization`, `…/octo/ghast` → `.repository`, trailing slash tolerated, non-github host / zero path components → `nil`.
- New `Ghast/Models/RunnerScope.swift`: `enum RunnerScope: Codable, Hashable, Sendable { case repository(fullName: String), organization(login: String) }`, explicit coding `{"kind":"repository"|"organization","name":…}`; extension `GitHubRepository.runnerScope`.
- Verify: `xcodegen && $T -only-testing:GhastTests/RunnerScopeTests`. Commit `✨ Add RunnerScope`.

## 2. Scoped runner endpoints (♻️ test-first)
- Test first — `GitHubAPIServiceRequestTests`: `@Test(arguments:)` over both scopes for list, registration token, remove token, delete, downloads (method, path, standard headers). Delete `fetchOrganizationRunnersUsesOrgPath`.
- Protocol + `GitHubAPIService`: `fetchRunners(in:)`, `createRegistrationToken(for:)`, `createRemoveToken(for:)`, `deleteRunner(runnerId:from:)`, `fetchRunnerApplications(for:)`. Remove `fetchOrganizationRunners` from protocol, `UnconfiguredGitHubAPIService`, `MockGitHubAPIService`, `GitHubAPIServiceTests:173`.
- Callers pass `repository.runnerScope`: `RepositoryDetailView` (:409, `ModernRemoteRunnerCard` :817 → `scope: RunnerScope`), `AddRunnerView` :811/:844, `DashboardView` :379.
- Verify: `$T -only-testing:GhastTests/GitHubAPIServiceRequestTests -only-testing:GhastTests/RepositoryDetailViewSnapshotTests -only-testing:GhastTests/DashboardViewSnapshotTests` (snapshots unchanged). Commit `♻️ Take RunnerScope in runner endpoints`.

## 3. Admin organizations (✨ test-first)
- Test first — request tests: `fetchAdminOrganizations` → `GET /user/memberships/orgs` with `state=active&per_page=100&page=1`; admin/member/admin memberships → two admin orgs decoded (`login`, `id`, `avatar_url`); full page of 100 requests page 2, short page stops.
- `GitHubModels.swift`: `GitHubOrganization: Codable, Identifiable, Hashable, Sendable { login, id, avatarURL }`, private `OrganizationMembership { role, organization }`.
- Extract `fetchAllPages<T>(path:query:)` from `fetchRepositories` (existing repo pagination tests guard it).
- Add `fetchAdminOrganizations()` to protocol, Unconfigured, mock (`mockOrganizations`, plus `failingScopes: Set<RunnerScope>` for steps 9–10).
- Verify: `$T -only-testing:GhastTests/GitHubAPIServiceRequestTests`. Commit `✨ Fetch organizations the user administers`.

## 4. Auth scopes + `needsScopeUpgrade` (✨ test-first)
- `FakeTransport.Reply.json` gains `headers: [String: String] = [:]` → `HTTPURLResponse(headerFields:)`.
- Test first — request test: `fetchCurrentUser` returns `AuthenticatedUser { user, grantedScopes: Set<String>? }` parsed from `X-OAuth-Scopes: repo, user:email, admin:org`; missing header → `nil`.
- `GitHubAuthServiceDeviceFlowTests` (injected `fetchUser`, `InMemoryTokenStore`, call `checkExistingAuth()` directly): (a) header with `admin:org` → flag false; (b) header without → flag true, token kept, `isAuthenticated` true; (c) header missing → flag true; (d) after (b), successful `signIn()` with `admin:org` clears flag; (e) after (b), failing `signIn()` leaves token and flag true. Also `GitHubAuthService.scopes == ["repo","user:email","admin:org"]`.
- `GitHubAuthService`: `fetchUser` returns `AuthenticatedUser`; `private(set) var needsScopeUpgrade` set from `grantedScopes?.contains("admin:org") != true` in `checkExistingAuth` and `runSignIn` success; `signOut` resets. Add `needsScopeUpgrade { get }` to `GitHubAuthServiceProtocol`; settable override in `MockGitHubAuthService`. Update device-flow test helper (:134) and `GitHubAPIServiceTests` call sites.
- Verify: `$T -only-testing:GhastTests/GitHubAuthServiceDeviceFlowTests -only-testing:GhastTests/GitHubAuthServiceTests -only-testing:GhastTests/GitHubAPIServiceRequestTests -only-testing:GhastTests/OAuthFlowIntegrationTests`. Commit `✨ Request admin:org and flag tokens that lack it`.

## 5. `LocalRunner.scope` persistence (✨ test-first)
- Test first — `RunnerServicePersistenceTests` / `LocalRunnerModelTests`: legacy JSON with only `"repository":"octo/ghast"` written to an isolated suite under `localRunners` loads as `.repository(fullName: "octo/ghast")` with all other fields intact; both scopes round-trip via encode/decode and save/load across two `RunnerService` instances.
- `LocalRunner`: `let scope: RunnerScope` replaces stored `repository`; custom `init(from:)` reads `scope`, else falls back to `repository`; custom `encode(to:)` writes all fields plus `repository = scope.displayName` (downgrade safety). Primary init `init(name:scope:path:labels:)`; convenience `init(name:repository:…)` forwards to `.repository` so existing tests stay unchanged.
- `RepositoryDetailView:14` filters on `$0.scope == repository.runnerScope`.
- Verify: `$T -only-testing:GhastTests/RunnerServicePersistenceTests -only-testing:GhastTests/LocalRunnerModelTests -only-testing:GhastTests/RunnerServiceTests`. Commit `✨ Persist RunnerScope on LocalRunner with legacy decoding`.

## 6. Discovery maps `.runner` URLs to a scope (🐛 test-first)
- Test first — temp `runnersDirectory` folders with `run.sh` and `.runner` (`gitHubUrl` = `https://github.com/acme` / `https://github.com/octo/ghast`); a new service discovers `.organization("acme")` and `.repository("octo/ghast")` (org case fails today: "Unknown/Repository").
- `RunnerService.discoverExistingRunners` (:900-908) uses `RunnerScope(gitHubURL:)`, keeps the `Unknown/Repository` fallback.
- Verify: same suite. Commit `🐛 Discover org runners from .runner files`.

## 7. Scope display in runner UI (🎨, no TDD — UI)
- New `Ghast/Views/RunnerScopeLabel.swift`: repo → `Text(fullName)` exactly as today; org → login + small "Org" capsule with `building.2`.
- Use in `LocalRunnersView:279`, `RunnerConfigurationView:114`, `RunnerLogsView:70`. Add one org-runner snapshot to `LocalRunnersViewSnapshotTests`; existing snapshots unchanged.
- Verify: `$T -only-testing:GhastTests/LocalRunnersViewSnapshotTests -only-testing:GhastTests/RunnerConfigurationViewSnapshotTests -only-testing:GhastTests/RunnerLogsViewSnapshotTests`. Commit `🎨 Show org runners with an org badge`.

## 8. Wizard takes a scope (✨ test-first)
- Test first — `RunnerServiceTests`: pure static `RunnerService.configArguments(url:token:name:labels:)` extracted from :246-252; `.organization("acme")` → `--url https://github.com/acme`, labels passed through.
- `createManagedRunner(name:scope:application:registrationToken:labels:)`; `configureRunner` uses `scope.configURL`.
- `AddRunnerView(scope:repository:onComplete:)` where `repository: GitHubRepository? = nil` is used only for the header's public/private icon (decision: keep the existing repo header pixel-identical); org header shows `RunnerScopeLabel` with `building.2`. Error copy uses `displayName`.
- `NewRunnerFlowView:115` and `RepositoryDetailView:51` pass `.runnerScope` + the repository.
- Existing `AddRunnerViewSnapshotTests` references must stay unchanged; add one org-scope snapshot.
- Verify: `$T -only-testing:GhastTests/RunnerServiceTests -only-testing:GhastTests/AddRunnerViewSnapshotTests -only-testing:GhastTests/NewRunnerFlowSnapshotTests`. Commit `✨ Create runners for a RunnerScope`.

## 9. Organizations sidebar + detail page
- 9a ♻️ Extract runner state, loading, local/remote filter, stats, list and delete flow from `RepositoryDetailView` into `Ghast/Views/ScopedRunnersPanel.swift` (`scope`, `onAddRunner`). `RepositoryDetailView` = header + panel. `RepositoryDetailViewSnapshotTests` references must stay byte-identical — if they drift, stop and investigate before re-recording. Commit `♻️ Extract ScopedRunnersPanel`.
- 9b test-first: `RunnerScopeTests` — `scope.errorMessage(for:)` returns "You need to be an owner of acme to manage its runners." for an org with `.httpStatus(403)` or `.notFound`; otherwise `localizedDescription`. Panel uses it. Commit `✨ Org error message`.
- 9c: `AppState` gains `organizations`, `isLoadingOrganizations`, `isScopeBannerDismissed`, `SelectedView.organization(GitHubOrganization)`. `MainAppView` routes to new `Ghast/Views/OrganizationDetailView.swift` (avatar + login header, `ScopedRunnersPanel(.organization(login))`, `AddRunnerView` sheet). `SidebarView` adds `organizationsSection` above `repositoriesSection`, hidden when empty or `needsScopeUpgrade`; load via `.task(id: authService.needsScopeUpgrade)` so a successful re-sign-in loads orgs. Snapshots: `SidebarViewSnapshotTests.testSidebarViewWithOrganizations`; new `OrganizationDetailViewSnapshotTests` (populated incl. one matching local runner that must be filtered out; empty). Existing sidebar references unchanged. Commit `✨ Organizations sidebar section and detail page`.
- Verify: `xcodegen && $T -only-testing:GhastTests/RunnerScopeTests -only-testing:GhastTests/SidebarViewSnapshotTests -only-testing:GhastTests/OrganizationDetailViewSnapshotTests -only-testing:GhastTests/RepositoryDetailViewSnapshotTests -only-testing:GhastTests/MainAppViewSnapshotTests -only-testing:GhastTests/AppStateTests`.

## 10. Dashboard counts include orgs (✨ test-first)
- Test first — new `GhastTests/RunnerStatsTests.swift`: `RunnerStats.load(scopes:fetch:)` sums total/online/busy across scopes; one org's fetch throwing still sums the other org and repos; cancellation propagates.
- New `Ghast/Models/RunnerStats.swift`; `DashboardView.loadRunnerStats` passes scopes of `repositories.prefix(10)` plus all orgs; reload on `onChange(of: appState.organizations)`.
- Verify: `$T -only-testing:GhastTests/RunnerStatsTests -only-testing:GhastTests/DashboardViewSnapshotTests`. Commit `✨ Count org runners on the dashboard`.

## 11. Scope-upgrade banner + in-app re-sign-in (🎨, no TDD — UI; auth logic covered in step 4)
- New `Ghast/Views/ScopeUpgradeBanner.swift`: "Sign in again to manage organization runners", Sign in + dismiss buttons. `MainAppView` shows it when `needsScopeUpgrade && !appState.isScopeBannerDismissed`.
- Sign in → `authService.signIn()`; sheet bound to `signInState` (`.awaitingUser` / `.failed`) reusing `DeviceCodePanel` / `SignInFailurePanel`. Move WelcomeView's once-per-attempt copy+open logic into a shared `DeviceFlowPresenter` in `DeviceFlowViews.swift`. Closing the sheet calls `cancelSignIn()`.
- Snapshots: new `ScopeUpgradeBannerSnapshotTests`; `WelcomeViewSnapshotTests` unchanged.
- Verify: `$T -only-testing:GhastTests/ScopeUpgradeBannerSnapshotTests -only-testing:GhastTests/WelcomeViewSnapshotTests -only-testing:GhastTests/MainAppViewSnapshotTests`. Commit `✨ Banner and in-app re-sign-in for admin:org`.

## 12. Integration gate
- Full suite: `heavy $T` (background).
- `xcode-remote` launch on Evan's laptop: old token → banner shows, Organizations hidden, repo pages work; after re-sign-in → Organizations appears.
- Owner action (Evan): one live org round trip (Add Runner → online → remove).
- Fresh-context `review` of `git diff main...HEAD` at the bar above.

## Risks
- `loadRunners` decodes `[LocalRunner]` all-or-nothing; one bad record drops all. Step 5 tests legacy and both new shapes; unknown `kind` still throws (out of scope).
- 403 heuristic: with `admin:org` requested, 403 on `/orgs/{org}` most likely means non-owner; could mislead if an org OAuth-app restriction is the cause.
- 9a touches the largest view; byte-identical snapshots are the guard.
- Step 4 assumes `X-OAuth-Scopes` lists `admin:org` literally when granted — verify with a real token at step 12.

## Decisions (orchestrator, 2026-11-15)
1. AddRunnerView keeps the repo header's public/private icon via an optional `repository` parameter (no visual change for repos).
2. `NewRunnerFlowView` stays repo-only; org runners are added from the org page (spec doesn't list a picker).
