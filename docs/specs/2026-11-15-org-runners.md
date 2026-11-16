# Org-level self-hosted runners

Status: approved 2026-11-15

## Goal
Create, list and remove GitHub Actions self-hosted runners at organization
level from Ghast, alongside the existing repository-level flow.

## Decisions
- **Scope request:** everyone signs in with `repo user:email admin:org`. No
  incremental second sign-in, no GitHub App.
- **Navigation:** a new "Organizations" sidebar section above Repositories,
  each org opening a detail page that mirrors the repository page.
- **Out of scope:** runner groups (new runners join the org's Default group),
  enterprise runners, showing which repos may use a runner, non-admin org views.

## Requirements

### Auth
1. `GitHubAuthService.scopes` becomes `["repo", "user:email", "admin:org"]`.
2. The existing `/user` validation reads the `X-OAuth-Scopes` response header.
   If it lacks `admin:org`, the auth service exposes `needsScopeUpgrade == true`.
   A missing header counts as lacking the scope. The token is kept and repo
   features keep working.
3. When `needsScopeUpgrade` is true, the main window shows a dismissible banner,
   "Sign in again to manage organization runners", whose action starts a fresh
   Device Flow. Dismissal lasts for the current launch only. A successful
   re-sign-in clears the flag.

### Organizations
4. Fetch orgs via `GET /user/memberships/orgs?state=active` (paginated like
   repositories). Keep only memberships with `role == "admin"`. Model:
   `GitHubOrganization { login, id, avatarURL }`.
5. The sidebar shows an "Organizations" section above Repositories listing
   those orgs. It is hidden when the list is empty, and while
   `needsScopeUpgrade` is true (the call would 403).
6. `AppState.SelectedView` gains `.organization(GitHubOrganization)`.
   `OrganizationDetailView` shows the org's remote runners (status, labels,
   busy), filters out runners that match a local runner (same rule as the
   repository page), offers Add Runner, and removes a remote runner with the
   same confirmation the repository page uses.

### API
7. Introduce `RunnerScope`: `.repository(fullName: String)` and
   `.organization(login: String)`. It supplies the API path prefix
   (`/repos/{fullName}` or `/orgs/{login}`) and the `config.sh --url`
   (`https://github.com/{fullName}` or `https://github.com/{login}`).
8. The runner endpoints take a `RunnerScope` instead of a repository: list
   runners, create registration token, create remove token, delete runner and
   list runner downloads. Repository callers pass `.repository`. The unused
   `fetchOrganizationRunners` is removed in favour of the scoped list call.

### Wizard and persistence
9. `AddRunnerView` (and `NewRunnerFlowView`, if it shares the path) takes a
   `RunnerScope`. `RunnerService.createManagedRunner` and `config.sh` use
   `scope.configURL`.
10. `LocalRunner` gains `scope: RunnerScope`, encoded explicitly. Decoding a
    stored runner that has only `repository` yields `.repository(fullName:)`.
    Existing UserDefaults data loads with no migration step and no data loss.
    UI that shows `repository` shows the scope's display name: the repo full
    name, or the org login with an org badge.
11. Discovery of existing runner folders maps a `.runner` `gitHubUrl` of
    `https://github.com/{owner}` (one path component) to `.organization`, and
    `https://github.com/{owner}/{repo}` to `.repository`, as it does today.

### Dashboard
12. Dashboard runner counts include org runners for listed orgs. A failure
    fetching one org does not hide the others or the repository counts.

## Errors
- 403/404 on an org endpoint shows the page's existing error state, with the
  message "You need to be an owner of {org} to manage its runners."
- A scope-upgrade sign-in that fails leaves the old token and the banner in place.

## Testing
- Request tests (FakeTransport): every scoped endpoint, for both scopes; the
  memberships call and admin filtering.
- Auth tests: header present with the scope, header present without it,
  header missing. Re-sign-in clears the flag.
- Persistence tests: decoding a legacy `LocalRunner` JSON blob; round-tripping
  both scopes.
- Discovery test: `.runner` URLs for org and repo.
- Snapshot tests: sidebar with the Organizations section, the
  `OrganizationDetailView` populated and empty states, and the scope-upgrade
  banner.
