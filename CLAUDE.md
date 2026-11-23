# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build System

This project uses **XcodeGen** to generate Xcode project files from `project.yml`. Always use this workflow:

```bash
# Generate/regenerate Xcode project
xcodegen

# Build the app
xcodebuild -project Ghast.xcodeproj -scheme Ghast build

# Run tests
xcodebuild test -project Ghast.xcodeproj -scheme Ghast

# Or use the MCP XcodeBuildMCP tools for better integration and output parsing
```

**Important**: The `Ghast.xcodeproj` is generated and git-ignored. All project configuration is in `project.yml`. Run `xcodegen` to regenerate the project after pulling changes.

## Architecture Overview

### Core App Structure
- **Single-instance macOS app**
- **SwiftUI + Combine** architecture with `@MainActor` services
- **GitHub Device Flow** sign-in (no client secret, no URL scheme)
- **Local process management** for GitHub Actions runners via `Foundation.Process`

### Key Components

**Authentication Flow**:
- `DeviceFlowClient`: RFC 8628 Device Flow against github.com; HTTP transport and sleeper are injected, so tests never touch the network or sleep
- `GitHubAuthService`: drives the flow and publishes `signInState` (`idle`, `awaitingUser(code)`, `failed(error)`, `signedIn`); stores the token through an injected `TokenStore` (`KeychainTokenStore` in production, Security.framework, service `net.evancoleman.ghast`)
- `WelcomeView` shows the user code, copies it and opens GitHub once per attempt
- OAuth app: Client ID `Ov23liLVIllxzZoRYwAN` with **Enable Device Flow** ticked; there is no client secret in the app

**Runner Management**:
- `RunnerService`: Singleton managing local GitHub Actions runners
- `LocalRunner` model: Persisted via UserDefaults, tracks process state
- Real-time log streaming via Combine `PassthroughSubject`
- Process lifecycle: start/stop runners using `./run.sh` in runner directories
- Shutdown: `/bin/bash` wrapper leads its own process group (Foundation `Process`); Ghast signals the group, never its own. Stop and quit send SIGTERM (Runner.Listener's handler ends its job and deletes its GitHub session; `run.sh` forwards nothing), then wait for the whole group to be gone, not just the wrapper, which dies at once. SIGKILL only after `RunnerService.stopGracePeriod` (15 s). `applicationShouldTerminate` returns `.terminateLater` until `stopAllRunners()` finishes, so Sparkle relaunches wait too. No machine-wide `pkill`
- Launch: `startRunner` first ends any leftover `Runner.Listener` whose path is in that runner's folder (found with `ps` through the injected `RunnerProcessScanning`), so a second copy never hits "A session for this runner already exists"
- VM runners (`.tart(image:)` backend, `TartBackend`) are on demand: no VM runs until a job asks for the runner. Each job gets a fresh clone (`ghast-<runnerID>-<6hex>`), deleted when the job ends. Up to 2 VMs per runner, and a global 2-VM budget shared by every runner, which counts macOS VMs Ghast didn't start (`.onDemand` state: connecting, waiting for jobs, standing by, booting, running n, waiting for a free VM slot). Each VM's log lines carry a `[vm a1b2c3] ` prefix (`PrefixedLogSink`)
- VM resources: `LocalRunner.vmResources` (`VMResources`: CPU cores, memory GB, disk GB, isolate network; blank is the image's value) is read live at each boot, so a change applies to the next VM only. After the clone, `TartBackend.applyResources` runs `tart set` with just the flags that are set (skipped when none is). A disk only grows: it is checked against `tart get` and left out of `set`, with one log line, when it isn't larger than the clone's. There is no in-guest resize step: the Cirrus images run `tart-guest-agent --run-daemon`, which grows the APFS container at boot (Step 0 results in `docs/specs/2026-11-19-tart-vm-resources.md`); an image without that daemon keeps its old partition size. Isolation runs `tart run --net-softnet` with `PATH=/usr/local/libexec/ghast:<inherited>`. The helper there is a root-owned setuid copy of softnet, installed by `Ghast/Resources/install-softnet-helper.sh` through `NSAppleScript` with administrator privileges (injected `PrivilegedScriptRunning`, `SoftnetHelperModel` drives it). Readiness comes from `SoftnetHelperChecker` (injected `FileInspecting` and `SoftnetVersionReading`): not installed, unsafe (symlink, owner, mode or a writable parent folder), outdated, ready or softnet missing. If it isn't ready, Ghast doesn't pull or clone, logs one line, shows `needsIsolationSetup`, and checks again on the next demand report or when the helper's status changes; it never boots an unisolated VM. Remove is in Settings › General. The Configuration tab warns (advisory) when any setting x `macOSVMLimit` exceeds the host's cores, memory or free space under `~/.tart` (`HostCapacity`, injected through `RunnerFlowServices`; the fixture uses `FixtureHostCapacity`)
- Demand comes from a `JobDemandSource` (`Ghast/Services/Demand/`), made per runner by `DemandSourceFactory`. The default is a runner scale set (`ScaleSetDemandSource`, a port of github.com/actions/scaleset @ 716908e: `ActionsServiceClient` + `ScaleSetMessageSession`, `api-version=6.0-preview`). If the service rejects the token, a repo runner falls back to REST polling of queued workflow jobs (`RESTPollingDemandSource`, ETag conditional requests every 15 s), and an org runner stops with an error. Remove deletes the scale set
- Job queue (multi-host): GitHub allows one message session per scale set, so two Macs running a VM runner of the same name share one job queue. The source's `run(_ context: DemandRunContext)` reports demand and a `JobQueueStatus` (`connecting`, `holding`, `heldElsewhere`, `released(sleep|handoff)`, `noQueue` for REST), and reads the runner's `QueueRole` and `idleSince` live. A 409 is waited out inside `ScaleSetDemandSource`, never thrown: a **Primary** (default, `LocalRunner.queueRole`) retries every 10 s, a **Standby** backs off 5→60 s. A standby holding the queue that has been idle 5 min deletes its session, waits a 30 s handoff window, then tries again, so a live primary takes the queue. All timings are `QueueTiming`, injected through `DemandSourceFactory`. `TartBackend` owns `OnDemandEntry.idleSince` (no demand and no VMs) and `OnDemandState.queue`, and logs each queue change once. On `NSWorkspace` sleep (`PowerEventSource`, `WorkspacePowerEvents`) every entry cancels its demand loop and deletes its session without blocking sleep; wake reopens it unless Stop ran meanwhile. Running VMs are left alone. REST fallback has no session, so role and queue status don't apply. Known limits: a crashed or offline primary keeps the session until GitHub expires it; two Standbys swap the queue about every 5 min and two Primaries never yield (the Configuration help says to set exactly one Primary)
- Workflows target a VM runner with `runs-on: <runner name>`; labels don't apply to VM runners (kept in the saved runner but hidden). Runners saved before on-demand show a one-time note (`LocalRunner.showsOnDemandNote`)

**UI Architecture**:
- Focus design: one main window (`FocusMainView`, sidebar of runners + detail with Output and Configuration tabs), a Welcome window for sign-in, a Settings window (General, Account), the New Runner sheet and a menu bar extra. Design tokens live in `Ghast/Design/` (`FocusColor`, `FocusType`, `FocusMetrics`)
- `MainSelection` (selected runner) and `AppWindowRouter` (opens windows from notifications and the menu bar) replace the old `AppState` navigation
- `AppDependencies` builds the services once; views read them from the environment (`focusContext`, `RunnerService`, `RemoteRunnerStore`, `GitHubAuthService`)
- `GitHubAPIService`: URLSession-based GitHub REST API client over an injected `HTTPTransport`

### Project Configuration
- **Bundle ID**: `net.evancoleman.ghast`
- **Single Instance**: `LSMultipleInstancesProhibited: true`
- **Dependencies**: Sparkle (updates), SnapshotTesting (UI testing); networking and Keychain use system frameworks
- **Target**: macOS 26.0+ (Liquid Glass, floating sidebar), SwiftUI lifecycle. Built with Xcode 27 locally; release CI pins Xcode 27.0 on the `xcode-27` image (GitHub preview, macOS 27 base). The code also compiles on Xcode 26.x

### Testing Strategy
- **Unit Tests**: Device Flow polling rules and auth state transitions, with fake transport and sleeper (Swift Testing)
- **Integration Tests**: runner service management
- **Snapshot Tests**: UI layout verification using swift-snapshot-testing
- **Mock Testing**: GitHub API responses and Device Flow responses

#### Snapshot Testing
Snapshots lock layout (glass and backdrop differ per macOS version, so they are covered by fidelity captures). All three suites are Swift Testing, parameterised over light and dark, and render against fixture dependencies:
- `FocusMainSnapshotTests`: detail column in states running, idle, stopped, starting, error, remote, empty, configuration, and VM states vmBooting, vmPulling, vmConfiguration, vmResourcesWarning, vmWaitingForJobs, vmTwoJobs, vmWaitingForSlot, vmStandingBy, vmHoldingStandby, vmIsolationSetup, vmIsolationUnsafe, vmIsolationOutdated
- `FocusFlowSnapshotTests`: welcome, welcome-failed, device-code, new-runner, new-runner-progress, new-runner-loading, new-runner-long-names, new-runner-load-failed
- `FocusSettingsSnapshotTests`: General, Account, Account with organization access not granted

#### Design fixture mode and fidelity scripts
- Debug builds launch into a canned screen with `-GhastDesignFixture <screen>` (`-GhastAppearance dark` for dark). Screens: main, configuration, remote, error, first-run, welcome, device-code, new-runner, new-runner-progress, new-runner-loading, new-runner-loaded, settings-general, settings-account, menu-bar (`Ghast/Fixture/`). Fixture mode uses a scratch folder, in-memory defaults and token store, and a fake GitHub API: it never touches real defaults, the Keychain, `~/.ghast`, Sparkle or running runners.
- `Scripts/fidelity/capture.sh <screen> [--dark]` builds Debug, starts a HiDPI virtual display, launches the fixture and captures it at 2x into `build/fidelity/` (needs Peekaboo with Screen Recording). `compare.sh <screen> [--dark]` writes a side-by-side and overlay against `docs/design/focus-redesign/`. Deviations are logged in `docs/design/focus-redesign/fidelity.md`.

**Recording new snapshots**:
Run `TEST_RUNNER_SNAPSHOT_RECORD_MODE=true xcodebuild test -project Ghast.xcodeproj -scheme Ghast -only-testing:GhastTests/<Suite>`, re-run without the variable to confirm green, then commit the PNGs in `GhastTests/__Snapshots__/` (the `TEST_RUNNER_` prefix is what forwards the variable to the test host).

**Running snapshot tests**: Always run after UI changes to verify layouts

### OAuth Debug Logging
Look for `🔐 OAuth:` prefixed logs in Console.app when debugging authentication issues.

### Local Runner Workflow
1. User opens the New Runner sheet (`NewRunnerSheet`) and picks scope, name, labels and group
2. `RunnerSetupFlow` downloads the runner, moves it into place, gets a registration token and runs `config.sh`
3. The registered runner is added to `RunnerService`; Remove, Reconfigure and Remove from GitHub go through `RunnerFlowCoordinator`, each behind a confirmation
4. Ghast manages runner lifecycle via `Process` and streams logs via Combine
5. Live output in `RunnerOutputView` (parsed by `OutputParser`, tailed by `LogTailer`) with scroll-to-end

## XcodeBuildMCP Tools

Claude Code has access to advanced Xcode build tools via MCP XcodeBuildMCP that provide better output parsing and integration:

### Available Tools:
- `test_macos_proj` - Run tests for macOS project with structured output
- `build_mac_proj` - Build macOS project with detailed error reporting  
- `clean_proj` - Clean build artifacts for project
- `list_schems_proj` - List available schemes in project

### Usage:
```
mcp__XcodeBuildMCP__test_macos_proj(projectPath: "/path/to/Ghast.xcodeproj", scheme: "Ghast")
```

**Benefits**: Better error parsing, structured output, integration with Claude Code workflow

## Development Notes

- **Git commits**: Always include emoji prefixes and Claude Code attribution in commit messages
- **Commit frequency**: Make logical, atomic commits frequently during development sessions - don't wait until the end to commit all changes at once
- **Commit organization**: Group related changes together (e.g., API fixes, UI improvements, new features) rather than mixing unrelated changes
- **Process debugging**: Runner logs stream to Console.app with detailed error messages
- **SwiftUI compatibility**: App targets macOS-specific modifiers (avoid iOS-only APIs)
- **UI testing**: Run snapshot tests after any UI changes to verify layout integrity