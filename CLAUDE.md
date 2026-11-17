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

**UI Architecture**:
- Focus design: one main window (`FocusMainView`, sidebar of runners + detail with Output and Configuration tabs), a Welcome window for sign-in, a Settings window (General, Account), the New Runner sheet and a menu bar extra. Design tokens live in `Ghast/Design/` (`FocusColor`, `FocusType`, `FocusMetrics`)
- `MainSelection` (selected runner) and `AppWindowRouter` (opens windows from notifications and the menu bar) replace the old `AppState` navigation
- `AppDependencies` builds the services once; views read them from the environment (`focusContext`, `RunnerService`, `RemoteRunnerStore`, `GitHubAuthService`)
- `GitHubAPIService`: URLSession-based GitHub REST API client over an injected `HTTPTransport`

### Project Configuration
- **Bundle ID**: `net.evancoleman.ghast`
- **Single Instance**: `LSMultipleInstancesProhibited: true`
- **Dependencies**: Sparkle (updates), SnapshotTesting (UI testing); networking and Keychain use system frameworks
- **Target**: macOS 26.0+ (Liquid Glass, floating sidebar), SwiftUI lifecycle. Built with Xcode 27 locally; release CI pins Xcode 26.6 on `macos-26`

### Testing Strategy
- **Unit Tests**: Device Flow polling rules and auth state transitions, with fake transport and sleeper (Swift Testing)
- **Integration Tests**: runner service management
- **Snapshot Tests**: UI layout verification using swift-snapshot-testing
- **Mock Testing**: GitHub API responses and Device Flow responses

#### Snapshot Testing
Snapshots lock layout (glass and backdrop differ per macOS version, so they are covered by fidelity captures). All three suites are Swift Testing, parameterised over light and dark, and render against fixture dependencies:
- `FocusMainSnapshotTests`: detail column in states running, idle, stopped, starting, error, remote, empty, configuration
- `FocusFlowSnapshotTests`: welcome, welcome-failed, device-code, new-runner, new-runner-progress
- `FocusSettingsSnapshotTests`: General, Account, Account with organization access not granted

#### Design fixture mode and fidelity scripts
- Debug builds launch into a canned screen with `-GhastDesignFixture <screen>` (`-GhastAppearance dark` for dark). Screens: main, configuration, remote, error, first-run, welcome, device-code, new-runner, new-runner-progress, settings-general, settings-account, menu-bar (`Ghast/Fixture/`). Fixture mode uses a scratch folder, in-memory defaults and token store, and a fake GitHub API: it never touches real defaults, the Keychain, `~/.ghast`, Sparkle or running runners.
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