# Plan — Tart VM Runners

Spec: `docs/specs/2026-11-18-tart-vm-runners.md` (source of truth on conflict). Branch `feat/tart-vm-runners`.
Test cmd: `xcodebuild test -project Ghast.xcodeproj -scheme Ghast -destination platform=macOS -only-testing:GhastTests/<Suite>` (written `T <Suite>`). Run `xcodegen` after adding files. Full suite only at the gate, under `heavy`, in background.

## Step 0 — Spike findings

| Item | Finding |
|---|---|
| Tart home | Moved to **github.com/openai/tart**; latest **2.42.0** (2026-11-17). Images still `ghcr.io/cirruslabs/macos-*`. |
| Homebrew | `brew install openai/tools/tart`. Old `cirruslabs/cli` tap no longer has the formula. Dionysus has stale **2.21.0** (pre-`exec`) → must reinstall. |
| run | `tart run --no-graphics --dir=<name>:<path>[:ro] <vm>`; macOS guest (13+) sees named share at `/Volumes/My Shared Files/<name>`. Process lives as long as the VM. |
| list | `tart list --format json [--source local\|oci]` → `[{Source, Name, Disk, Size, Accessed, Running, State}]`. **No OS field.** |
| get | `tart get <vm> --format json` → `{OS, CPU, Memory, Disk, DiskFormat, Size, Display, MACAddress, Running, State}`; `OS` = `darwin`/`linux`. |
| stop/delete | `tart stop <vm> [--timeout <s>]`; `tart delete <vm>...` |
| pull/clone | `tart pull <oci-ref>`; `tart clone <src> <new>` pulls implicitly but Ghast pulls explicitly for progress. |
| exec | `tart exec [-i] [-t] <vm> <cmd...>`, since **2.27.0**; needs Tart Guest Agent in guest. |
| Guest agent | cirruslabs `base` installs `tart-guest-agent` (LaunchAgent + daemon); `-xcode` builds on base → has it. **`-vanilla` does not.** |
| JIT | `POST /repos/{o}/{r}/actions/runners/generate-jitconfig` or `/orgs/{org}/…`, body `{name, runner_group_id:int, labels(1–100), work_folder?}` → 201 `{runner:{id}, encoded_jit_config}`. Guest: `./run.sh --jitconfig <encoded>`; one job then auto-deregister. |
| Delete | `DELETE …/actions/runners/{id}` → 204; treat 404 as gone. |
| Token | Device Flow token is classic OAuth; needs `repo` / `admin:org`+`repo` + admin. `GitHubAuthService.scopes` already `["repo","user:email","admin:org"]` → **no auth change**. |

**Guest channel: `tart exec`.** No creds, no IP polling, no known-hosts; streams stdout/stderr + exit code into the log; `tart exec <vm> /usr/bin/true` is the readiness probe. Costs: Tart ≥ 2.27.0; custom images must ship the guest agent (boot-timeout error says so). Agent bug `openai/tart-guest-agent#83` (vsock early-close kills RPC) is contained by ephemerality.

**Step 0b results (2026-11-18, Tart 2.42.0, macos-tahoe-base guest 26.6.2):**
- Pull of `macos-tahoe-base:latest`: ~12 min, 33 GB on disk (50 GB logical). Clone near-instant.
- `tart list` shows the pulled image **twice**: by tag `ghcr.io/cirruslabs/macos-tahoe-base:latest` and by digest `…@sha256:…`, both `Source: OCI`. Presence check: exact-name match on the ref works.
- JSON type quirk: `list` `Size` is an Int (GB) but `get` `Size` is a **String** (`"32.673"`). Decode both leniently / ignore Size.
- `get` returns `OS: "darwin"`, CPU 4, Memory 8192 for the cloned VM.
- `tart exec <vm> /usr/bin/true` succeeded ~20 s after `tart run` (first probes fail fast while booting).
- Share `/Volumes/My Shared Files/ghast` was mounted at first successful exec.
- Guest user `admin`, `$HOME=/Users/admin`.
- Killing the host `tart exec` process (SIGTERM) **also ends the guest command** (`sleep` gone). pkill-first stop stays as defense in depth.
- Curated tags `macos-tahoe-xcode`, `macos-sequoia-base`, `macos-sequoia-xcode` `:latest` all resolve (HTTP 200).
- `tart stop` + `tart delete` cleaned the clone fully.
- Still open (needs a GitHub live run at the gate): default labels on JIT runners; JIT name length limit.

**Step 0b — live-only checks** (original list):
1. Does killing host `tart exec` stop the guest command? (Stop uses `tart exec <vm> pkill -TERM -f Runner.Listener` first regardless.)
2. Is `/Volumes/My Shared Files/ghast` mounted by the time the agent answers?
3. Does GitHub add default labels (`self-hosted`, `macOS`, `ARM64`) to JIT runners? (Plan sends them explicitly, de-duped.)
4. Curated tags resolve: `macos-{tahoe,sequoia}-{base,xcode}:latest`.
5. `tart list` names a pulled OCI image by full ref (presence check relies on it).
6. JIT name length limit with `-<6hex>` suffix.

```
tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest gs
tart run --no-graphics --dir=ghast:$CACHE:ro gs &
tart exec gs /usr/bin/true
tart exec gs ls "/Volumes/My Shared Files/ghast"
tart exec gs /bin/bash -lc 'sleep 300' & kill %2
tart exec gs pgrep sleep
tart stop gs; tart delete gs
```

## Steps (one commit each, in order; [effort])

### 1. Backend kind on LocalRunner [low]
- `Models/LocalRunner.swift`: `enum RunnerBackendKind: Codable, Hashable, Sendable { case host, tart(image: String) }`; `backend` field, `decodeIfPresent ?? .host`, encoded.
- New `Models/TartImageCatalog.swift`: static `(title, ref)` list for `macos-tahoe-base`, `macos-tahoe-xcode`, `macos-sequoia-base`, `macos-sequoia-xcode` (`:latest`); `isOCIRef(_:)` (contains `/`).
- Failing test `LocalRunnerMigrationTests`: old JSON → `.host`; `.tart(image:)` round-trips. Verify `T LocalRunnerMigrationTests`.

### 2. JIT config API [medium, TDD]
- `Protocols/GitHubAPIServiceProtocol.swift`: `generateJITConfig(for: RunnerScope, name:, runnerGroupID: Int, labels: [String], workFolder:) async throws -> GitHubJITConfig { runnerID: Int; encodedConfig: String }`; inert default on `UnconfiguredGitHubAPIService`. Implement in `Services/GitHubAPIService.swift`.
- `deleteRunner` treats 404 as success (separate method if existing callers rely on the 404 error). Add `id` to `GitHubRunnerGroup` if missing.
- Extend `MockGitHubAPIService`, `FlowGitHubAPI` with recorded calls.
- Failing tests `GitHubJITConfigTests` (FakeTransport): repo/org paths, body fields with int group id, 201 decode, 422 → error, delete 404 → success.

### 3. TartCLI + TartLocator [medium, TDD]
- `Ghast/Services/Tart/TartCLI.swift`: `protocol TartCLI: Sendable` — `list()`, `os(of:)`, `pull(_:log:)`, `clone(_:_:)`, `run(_:shares:log:) -> RunnerProcessHandle` (long-lived), `exec(_:_:) -> Int32`, `execStreaming(_:_:log:onExit:) -> RunnerProcessHandle`, `stop(_:timeout:)`, `delete(_:)`.
- `ProcessTartCLI`: short calls via `ProcessRun.run`; long-lived via `RunnerProcessLauncher`. Add optional `appendOutputTo: URL?` to `RunnerLaunchSpec`.
- Pure helpers `TartArguments` (argv) and `TartJSON` (list/get decode).
- `TartLocator.swift`: `/opt/homebrew/bin/tart` → `/usr/local/bin/tart` → `$SHELL -lc 'command -v tart'`; then `tart --version` → `.found(URL, version)` / `.tooOld(URL, version)` / `.missing`. File checks and shell runner injected; min version constant `2.27.0`.
- Failing tests `TartCLIParsingTests`, `TartLocatorTests`: list/get JSON samples, `run` argv with `:ro` share, `exec` argv, fallback order, version compare (2.27.0, 2.9.0, 2.42.0).

### 4. RunnerBackend seam + BareMetalBackend (pure refactor) [high]
- `Services/Backends/RunnerBackend.swift`: `@MainActor protocol RunnerBackend` — `start(_:) async throws`, `stop(id:) async`, `isRunning(id:)`, `logFile(for:)`, `stopAll() async`; state changes via injected `(String, RunnerProcessState) -> Void`.
- Move `launchRunner`, `requestStop`, `escalateStop`, `didTerminate`, leftover-listener cleanup from `Services/RunnerService.swift` (:168–:491) into `BareMetalBackend.swift` **unchanged**. `RunnerService` keeps `processStates`, persistence, public API; dispatches on `runner.backend`. Keep `RunnerService.stopGracePeriod`.
- No new tests; existing suites must pass unchanged: `T RunnerServiceTests RunnerProcessLifecycleTests RunnerShutdownTests ProcessGroupSafetyTests ConcurrentRunnerOperationsTests RunnerWrapperTests`.

### 5. Status phases [medium, TDD]
- `Models/RunnerProcessState.swift`: add `pulling`, `booting`, `cleaningUp`; `restored(from:)` maps them to `.stopped`.
- `Models/RunnerDisplayStatus.swift`: matching cases across `make`, `title`, `sidebarSubtitle`, `secondaryLine`, `toolbarButtons` (Stop enabled), `spokenState`. Spinner in `RunnerStatusHeader.swift`; colour in `StatusDot.swift`; update `MenuBarMenuModel`.
- Failing tests `RunnerDisplayStatusTests`: per phase title/subtitle/buttons.

### 6. TartBackend loop [xhigh, TDD]
New in `Services/Backends/`: `TartBackend.swift`; `TartLeaseStore.swift` (defaults-backed `[cloneName: (runnerLocalID, jitRunnerID?, scope)]`); `RunnerTarballCache.swift` (`~/.ghast/tart-cache/`, filename from `fetchRunnerApplications` osx/arm64 URL, download only if absent, via `RunnerDownloader`); `TartGuestScript.swift` (pure builder). Injected: `TartCLI`, GitHub API, `Sleeper`, clock, `RunnerDownloader`, id generator.

Iteration:
1. Image present (`list`)? Missing OCI ref → `.pulling`, log "Pulling image…", `pull`. Missing local name → error state.
2. Ensure tarball cached.
3. Under a **backend-wide serial gate**: count running VMs with `os == "darwin"`; ≥ 2 → error with 2-VM message. Else `clone` → `ghast-<runner.id>-<6hex>`, record lease, `.booting`, log "Booting VM…", `run`.
4. Poll `exec /usr/bin/true` via sleeper until `bootTimeout` (180 s); timeout → cleanup + error naming the guest agent.
5. `generateJITConfig`: name `<runner.name>-<6hex>`; labels defaults + custom de-duped; group id 1 for repo, org resolves name via `fetchRunnerGroups`; work folder; store JIT id in lease.
6. Log "Waiting for job", `.running`, `execStreaming` `/bin/bash -c <TartGuestScript> _ <jit>` (extract `/Volumes/My Shared Files/ghast/<tarball>` → `~/actions-runner`, `./run.sh --jitconfig "$1"`). **JIT config never logged.**
7. On exit: `.cleaningUp`, log "Cleaning up", `stop`, `delete`, `deleteRunner` (404 ok), clear lease.
8. Loop while `shouldBeRunning`; failed iteration waits `restartDelay`.

Stop: `exec <vm> pkill -TERM -f Runner.Listener` → wait ≤ `stopGracePeriod` for streaming exec → terminate it → step 7 cleanup.

Failing tests `TartBackendTests` (`FakeTartCLI` ordered call log, `FlowGitHubAPI`, `ManualSleeper`): happy path exact call order + lease cleared; pull-when-missing (`.pulling` + log line); boot timeout (stop+delete, error, no JIT); 2-VM refusal counting a non-Ghast darwin VM, ignoring Linux, no clone; stop mid-job (pkill → stop, delete, `deleteRunner(jitID)`); tarball reused on 2nd iteration, re-downloaded when filename changes.

### 7. Launch recovery + quit [medium, TDD]
- `TartBackend.recoverLeftovers()`: `stop`+`delete` every `ghast-*` in `list`; `deleteRunner` for each lease; log failures (`Logger`), continue.
- Called once at launch from `AppDependencies.live`/`AppDelegate`, gated by `LaunchPlan`; never in fixture mode or under XCTest.
- `RunnerService.hasRunningProcesses` / `stopAllRunners()` include Tart slots so `applicationShouldTerminate` (`GhastApp.swift:455`) stays `.terminateLater` until VMs are deleted. `killRemainingRunners` best-effort sync `tart stop`.
- Failing tests: `TartBackendTests.recovery` (two `ghast-*` + one unrelated; only Ghast deleted; a `deleteRunner` failure doesn't stop the rest); `RunnerShutdownTests` (Tart slot active → `hasRunningProcesses` true).

### 8. New Runner sheet + VM creation path [high, TDD + snapshots]
- `Views/Focus/NewRunner/NewRunnerConfigureView.swift`: "Run in" segmented (This Mac default / Tart VM). Tart VM → image picker (`TartImageCatalog` + "Custom…" text field); Architecture picker hidden. `TartLocator` `.missing`/`.tooOld` → option disabled, shows `brew install openai/tools/tart` with copy button.
- `NewRunnerRequest.backend`; `TartLocator` via `RunnerFlowServices`.
- `Provisioning/RunnerSetupFlow.swift`: `.tart` skips download/registration/`config.sh`; create runner folder (log only), `addLocalRunner(backend: .tart(image:))`, `startRunner`; single progress step.
- Failing tests `RunnerSetupFlowTests` VM path: no `createRegistrationToken`, no registrar, saved with backend, started.
- Snapshots `FocusFlowSnapshotTests`: `new-runner-tart`, `new-runner-tart-missing` (light/dark); record then re-run green.

### 9. Remove, Reconfigure, Configuration tab, detail snapshots [medium, TDD + snapshots]
- `RunnerRemover.remove` `.tart`: stop slot (does cleanup), drop entry; no `config.sh remove`/remove token.
- `RunnerFlowCoordinator.requestReconfigure` `.tart`: save labels, group, image to `LocalRunner`; no re-registration; next iteration picks up.
- `RunnerConfigurationForm.swift`: hide environment (:102) and job scripts (:196) for VM runners; show image field.
- Failing tests: `RemoveRunnerTests` (no registrar/remove token; clone deleted; entry gone); `ReconfigureTests` (fields persisted; no registration).
- Fixture `.phase(RunnerProcessState)` in `FixtureProcessScript` (`Fixture/FixtureRunners.swift`); `FocusMainSnapshotTests` states `vm-booting`, `vm-pulling`.

## Integration gate
1. Load check; `heavy xcodebuild test -project Ghast.xcodeproj -scheme Ghast -destination platform=macOS` in background; all snapshots green.
2. `review.concurrency` of `git diff main...HEAD` (slot loop, boot gate, quit wait). Bar: fix P0/P1 and user-hittable; rest → accepted risks.
3. Live check on Dionysus (Tart ≥ 2.27): VM runner (`macos-tahoe-base`) on a test repo runs a workflow; `ghast-…` appears in `tart list` then disappears; JIT runner gone on GitHub; Stop mid-job removes VM + runner; quit with active slot waits then no `ghast-*`; force-quit + relaunch recovers; 3rd macOS VM gets 2-VM error.
4. Fidelity capture `new-runner` only if the sheet layout visibly changed.

## Risks (accepted unless noted)
- Step 4 is the biggest regression risk (~300 lines of shutdown logic moved). Pure move, guarded by existing suites.
- Guest agent `#83`: guest code can wedge `exec`; worst case one failed iteration.
- JIT config in host/guest argv (visible to `ps`) for the job's life; single-use, ephemeral VM, never logged.
- Boot gate only serialises Ghast slots; a foreign VM racing in surfaces as boot failure → error state.
- Disk: base ~25 GB, Xcode far more; full disk → error state with tart's message.

## Decisions (Evan)
1. Minimum Tart 2.27.0 for `tart exec`; older Tart disables the option like missing and shows reinstall command. (Pending.)
2. `-vanilla` images excluded from curated list; Custom refs not validated up front. (Pending: note on Custom?)

Sources: tart.run/quick-start; github.com/openai/tart (+releases); github.com/cirruslabs/tart-guest-agent, openai/tart-guest-agent#83; github.com/cirruslabs/macos-image-templates; docs.github.com REST self-hosted runners; crabbox.sh/providers/tart.html; crowci.dev Tart backend.
