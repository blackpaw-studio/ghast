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

# Or use the MCP XcodeBuildMCP tools for better integration
```

**Important**: Never edit `Ghast.xcodeproj` directly. All project configuration is in `project.yml`.

## Architecture Overview

### Core App Structure
- **Single-instance macOS app** with custom URL scheme handling (`ghast://`)
- **SwiftUI + Combine** architecture with `@MainActor` services
- **OAuth flow** using both AppDelegate and SwiftUI URL handlers for maximum compatibility
- **Local process management** for GitHub Actions runners via `Foundation.Process`

### Key Components

**Authentication Flow**:
- `GitHubAuthService`: Manages OAuth with GitHub, uses Keychain for token storage
- Dual URL handling: `AppDelegate.handleGetURLEvent` + SwiftUI `onOpenURL`
- NotificationCenter bridges URL callbacks to auth service
- OAuth credentials: Client ID `Ov23liLVIllxzZoRYwAN`, redirect URI `ghast://auth/callback`

**Runner Management**:
- `RunnerService`: Singleton managing local GitHub Actions runners
- `LocalRunner` model: Persisted via UserDefaults, tracks process state
- Real-time log streaming via Combine `PassthroughSubject`
- Process lifecycle: start/stop runners using `./run.sh` in runner directories

**UI Architecture**:
- `AppState`: Central navigation state (`SelectedView` enum)
- Navigation: Dashboard → Repository Detail → Local Runners → Settings
- `GitHubAPIService`: Alamofire-based GitHub REST API client
- Environment objects flow: `GitHubAuthService` + `AppState` injected throughout

### Project Configuration
- **Bundle ID**: `net.evancoleman.ghast`
- **URL Scheme**: `ghast://auth/callback` (OAuth redirect)
- **Single Instance**: `LSMultipleInstancesProhibited: true`
- **Dependencies**: Alamofire (networking), KeychainAccess (secure storage)
- **Target**: macOS 15.0+, SwiftUI lifecycle

### Testing Strategy
- Comprehensive OAuth flow testing without manual intervention
- Mock GitHub API responses and URL callback simulation
- Integration tests for NotificationCenter-based OAuth bridge
- Runner service tests for local process management

### OAuth Debug Logging
Look for `🔐 OAuth:` prefixed logs in Console.app when debugging authentication issues. The flow includes detailed logging at each step: URL generation, callback reception, code extraction, token exchange, and user fetch.

### Local Runner Workflow
1. User creates runner via GitHub API (gets registration token)
2. User downloads and configures runner binary locally
3. User registers runner path with Ghast via `AddRunnerView`
4. Ghast manages runner lifecycle via `Process` and streams logs via Combine
5. Real-time log viewing in `RunnerLogsView` with automatic scroll-to-bottom

## Development Notes

- **Git commits**: Always include emoji prefixes and Claude Code attribution in commit messages
- **URL scheme testing**: Use `open "ghast://auth/callback?code=test"` to simulate OAuth callbacks
- **Process debugging**: Runner logs stream to Console.app with detailed error messages
- **SwiftUI compatibility**: App targets macOS-specific modifiers (avoid iOS-only APIs)