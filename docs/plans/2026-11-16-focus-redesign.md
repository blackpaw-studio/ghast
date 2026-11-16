# Focus redesign: implementation plan

Spec: `docs/specs/2026-11-16-focus-redesign.md` (approved; it wins over this plan). Design: `docs/design/focus-redesign/` (PNG > kit.md > spec). Five PRs in order. PR 1 is cut from `feat/focus-redesign` and carries the spec and this plan. Each later PR branches from `main` after the previous one merges: `feat/focus-2-main`, `-3-flows`, `-4-settings`, `-5-cleanup`.

## Conventions
- Run `xcodegen` after any step that adds or removes files.
- `B="xcodebuild build -project Ghast.xcodeproj -scheme Ghast -destination platform=macOS"`
- `T="xcodebuild test -project Ghast.xcodeproj -scheme Ghast -destination platform=macOS"`
- Run targeted suites directly with `$T -only-testing:GhastTests/<Suite>`.
- Run the full suite only at each PR gate, as `heavy $T` in the background, after checking `uptime`. Above ~30, defer it and say so.
- Record snapshots with `TEST_RUNNER_SNAPSHOT_RECORD_MODE=true $T -only-testing:…`, re-run without the variable to confirm green, then commit the PNGs.
- `F=Scripts/fidelity`. Git tracks `Scripts/`; the spec's `scripts/` is the same folder on this case-insensitive volume. Commands: `$F/capture.sh <screen> [--dark]` and `$F/compare.sh <screen> [--dark]`. Output goes to `build/fidelity/` (gitignored). Dispatches return file paths; the orchestrator posts side-by-sides to Evan with `leo_chat_post`.
- New tests use Swift Testing. Inject the clock, sleeper, file trasher and process launcher. No real sleeps or network.
- Commits are emoji-prefixed and each one compiles. No new singletons: new services go through `AppDependencies` or the environment.
- Step types:
  - **[M]** mechanical: `implement`, medium effort.
  - **[L]** logic, test-first: `implement`, high effort.
  - **[V]** visual fidelity: `implement.design`. Snapshot and fidelity checks, no unit tests.
  - Each PR names the role for its single brief.
- Review bar, the same for every PR: fix P0/P1 and anything a real user can hit:
  - loss of `localRunners` or a runner folder
  - a runner unregistered or trashed without confirmation
  - runners orphaned or left running after quit
  - the wrong status shown (an error shown as idle)
  - notification spam
  - fixture mode touching real defaults, the Keychain or `~/.ghast`
- Don't cut a release from `main` until PR 5 merges.

## PNG reconciliation (the PNGs win; the spec text was written before they existed)
- **Configuration.png**
  - No status header on the Configuration tab: the form starts under the toolbar. The header and label tokens belong to the Output tab.
  - The Runner section has Name, Scope, Labels and Folder (+ Show in Finder). There is no Version row.
  - The form has a max width (≈760 pt; measure it into `FocusMetrics.configurationMaxWidth`).
  - Environment-variable rows are mono, with a name column of ≈260 pt.
  - No "Scripts run with bash…" help text.
  - "Remove Runner…" is a borderless red text button.
- **ErrorRunner.png**
  - The toolbar capsule shows Start plus a *disabled* Restart. This also applies to stopped runners.
  - Header order: title, secondary line, labels, then one row with the hint text, Start Runner and Reconfigure….
  - Stats are **Last Run** "1 h 02 min", Jobs Today, Version. Stopped or error runners show Last Run, the duration of the last run; Uptime shows only while running.
  - Minutes are zero-padded when hours are present ("1 h 02 min").
  - Error lines get a red `xmark.circle.fill` glyph and primary-colour text.
  - The last visible line is the runner's own. Ghast's "Runner exited with code N" line is **not shown**: the `ghast: exit` marker stays hidden and the header carries the code.
  - The ghast-release fixture log is copied line for line from this PNG.
- **RemoteRunner.png**
  - Subtitle reads "{scope} · Other machine".
  - Secondary line reads "Online and waiting for jobs".
  - Stats are Machine "Other machine" and OS "Linux X64", from `GitHubRunner.os` plus the architecture label.
  - The note has a terminal glyph, then "Output Is on That Machine" over "Ghast shows live output only for runners on this Mac."
- **Defaults not drawn** (the orchestrator decided these; Evan can veto):
  - Remote busy secondary line: "Online and running a job".
  - Remote offline secondary line: "Not connected to GitHub".
  - Error hint: "The runner isn't configured. Reconfigure it, or check the output for details." when the log has `Not configured` or the registration was deleted. For any other error: "Check the output for details."

---

## PR 1 · Foundation (brief: `implement`, high)

### 1.1 Capture gate (spec risk #1) [M] (blocks everything after it)
The host facts found during planning make this a real risk:
- `screencapture` fails with "could not create image from display" because Screen Recording isn't granted.
- The only display is the PiKVM at 1680×1050, apparently 1x.
- A 2x capture of a 1240×780 window needs a HiDPI display of at least 1440×900 pt.

Steps:
- Find which process TCC holds responsible for the denial: run `log show --last 5m --predicate 'subsystem == "com.apple.TCC"'` right after a failed `screencapture -x`. Report it so the orchestrator can ask Evan for the grant (owner action A).
- After Evan approves (owner action B), add `$F/virtual-display/`. It is a small Swift CLI built with `swiftc`. It creates a 2880×1800 HiDPI `CGVirtualDisplay` (private CoreGraphics SPI, declared in a bridging header the way DeskPad does it). It runs only while a capture runs and is never shipped.
- Add `$F/probe/GlassProbe.swift`, a throwaway SwiftUI app with a `NavigationSplitView`, a sidebar, glass toolbar groups, and a striped backdrop window behind it.
- `$F/probe.sh` does the following:
  1. Starts the virtual display.
  2. Places the probe there.
  3. Captures it with `screencapture -l <id> -o`, and the same rect with `screencapture -R`.
  4. Asserts the window capture is exactly 2× the window size.
  5. Asserts the sidebar region shows blurred stripes (`magick` variance between 0 and the source's), so glass sampled its backdrop.
  6. Asserts the `-l` and `-R` captures agree (`compare -metric RMSE` under a threshold).
- Verify: `$F/probe.sh` exits 0. The orchestrator posts the probe PNG to Evan.
- **If any assertion fails: stop and decide a fallback with Evan** (for example, capture on his laptop). Commit: `🔧 Prove 2x Liquid Glass window capture on the build host`.

### 1.2 macOS 26 minimum [M]
- In `project.yml`, set `deploymentTarget.macOS` and `LSMinimumSystemVersion` to `"26.0"`. `release.yml` already derives `MIN_OS` from `LSMinimumSystemVersion`.
- Set `.github/workflows/release.yml` `xcode-version` to 27.x if the `macos-26` image ships it. Otherwise leave 26.6 and record that in the PR body; step 5.4 checks a 26.x build.
- Verify: `xcodegen && $B`, plus `$T -only-testing:GhastTests/GhastAppTests`. Commit: `⬆️ Require macOS 26`.

### 1.3 Injected environment [M]
- New `Ghast/Support/`:
  - `Clock` (`now()`) and `Sleeper` (reuse DeviceFlowClient's if it fits)
  - `HostInfo` (`computerName`, `architecture`)
  - `FileTrasher` (`NSWorkspace.recycle`)
  - `RunnerProcessLauncher` (wraps `Process`)
- Add live implementations to `AppDependencies`, and test fakes in `GhastTests/Mocks/`.
- Verify: `$B`. Commit: `♻️ Inject clock, host info, trasher and process launcher`.

### 1.4 Fixture launch mode skeleton and capture scripts [M] (proves the fixture before any logic)
- `Ghast/Fixture/` is all `#if DEBUG`. It has:
  - `FixtureLaunch` parsing of `-GhastDesignFixture <screen>`, `-GhastAppearance dark` and the 12 screen names.
  - `FixtureDependencies`: a volatile `UserDefaults` suite, a temp runners folder, an in-memory token store, `FixtureGitHubAPIService`, the frozen clock (Mon 16 Nov 2026 10:12 local), and host "Dionysus".
  - A backdrop window with the kit's `--desk` gradient for light or dark.
  - Window placement at the mockup offset (main window at 100,60 on a 1440×900 pt HiDPI screen).
  - A `fixture-ready window=<windowNumber>` line on stdout once layout settles.
- In fixture mode `AppDelegate` skips the single-instance check, Sparkle, signal handlers and runner cleanup. `GhastApp.isRunningTests` stops matching on argument substrings.
- Test first, `FixtureSafetyTests`: fixture dependencies never use `UserDefaults.standard`, `RunnerService.defaultRunnersDirectory` or the Keychain store.
- `$F/capture.sh` does the following:
  1. Builds Debug into `build/DerivedData`.
  2. Starts the virtual display.
  3. Launches the fixture.
  4. Waits for the ready line, with a 30 s cap.
  5. Runs `screencapture -l <id> -o` and writes `build/fidelity/<screen>[-dark].png`.
  6. For `menu-bar`, uses a region capture of the display instead.
- `$F/compare.sh` crops the mockup to the window rect ×2 with `magick`, then writes a side-by-side and a 50% overlay.
- New `docs/design/focus-redesign/fidelity.md` with one table per screen. Seed it with the known native differences from the spec.
- Verify:
  - `$T -only-testing:GhastTests/FixtureSafetyTests`
  - `$F/capture.sh main && $F/compare.sh main` against the **old** UI, which only proves the pipeline. Post it.
- Commit: `🧪 Design fixture launch mode and fidelity scripts`.

### 1.5 Output parser and activity [L]
- Test first, new `OutputParserTests`:
  - each kind
  - ISO `%Y-%m-%dT%H:%M:%S%z` and legacy `HH:MM:SS` prefixes
  - runner `YYYY-MM-DD HH:MM:SSZ: ` prefix stripped
  - blank lines dropped
  - CRLF
  - a partial trailing line held back
  - incremental offsets
  - truncation restarts from 0
  - version
  - the current job across start, end and Listening
  - `ghast: start` resets listening and the current job
  - `ghast: exit code=N` hidden, recorded and producing no line
  - the 5,000-line cap
  - Jobs Today across midnight with a fixed calendar and time zone
  - error-prefix lines
  - the kit's dionysus-xcode log gives 5 jobs today, version 2.329.0, current job build-and-notarize
- New `Ghast/Models/Output/`: `OutputLine` (`timestamp`, `text`, `kind`), `JobRecord`, `RunnerActivity` (spec §Data model 3), and `OutputParser`, a pure `consume(_ data: Data, into: ParserState) -> ParserState`.
- Verify: `xcodegen && $T -only-testing:GhastTests/OutputParserTests`. Commit: `✨ Parse runner output into activity`.

### 1.6 Duration format [L]
- Test first, `DurationFormatTests`:
  - `3 h 14 min`, `1 h 02 min`, `45 min`, `2 d 3 h`, `—`
  - "started just now" under 1 min, then `started {n} min ago` rounded to the nearest minute
  - spoken forms ("3 hours 14 minutes")
- Verify: `$T -only-testing:GhastTests/DurationFormatTests`. Commit: `✨ Duration formatting`.

### 1.7 `LocalRunner` fields and migration [L]
- Test first, extend `LocalRunnerModelTests`:
  - legacy JSON without the new keys decodes with defaults
  - legacy `status: running` maps to `shouldBeRunning = true`
  - records that have `shouldBeRunning` ignore `status`
  - round trip through two `RunnerService` instances
  - the encoder still writes `status` ("running"/"stopped" from `shouldBeRunning`) so 1.1.0 can decode after a downgrade, the same precedent as `repository`
- Add `shouldBeRunning`, `lastExit: RunnerExit?` (`code`, `startedAt`, `at`, `wasRequested`), `outputClearOffset: UInt64`, `runnerGroup: String?` and `workFolder` (default `_work`). The `status` property stays only until step 5.1.
- Verify: `$T -only-testing:GhastTests/LocalRunnerModelTests -only-testing:GhastTests/RunnerServicePersistenceTests`. Commit: `✨ Persist run intent, last exit and output clear point`.

### 1.8 Wrapper exit codes and process state [L] (data-integrity sensitive)
- Test first, new `RunnerWrapperTests`. These are real `/bin/bash` runs against a temp folder with a fake `run.sh` and `restartDelay: 0`:
  - exit 1 ends the process with exit 1, writes `ghast: start` and `ghast: exit code=1` with ISO stamps, and sets state `.exited`, `lastExit.wasRequested == false`, `shouldBeRunning == false`
  - exit 0 once then 1 gives one restart (two `ghast: start` markers), then the error
  - a requested `stopRunner` gives `.stopped`, `wasRequested`, and `shouldBeRunning == false`
  - `stopAllRunners` (quit) is a requested stop but **keeps** `shouldBeRunning`
  - an uncaught signal maps to code 128+n
- Extract `RunnerWrapperScript.make(runnerPath:logFile:parentPID:restartDelay:)`. Today it always exits 0 (`RunnerService.swift:374-433`). It must end with `exit $EXIT_CODE`. Delete the Swift-side emoji log writes (`:443-509`).
- Add `RunnerProcessState` and `processStates` published on `RunnerService`, plus a stop-requested set and `clock.now()` stamps.
- `clearRunnerLogs` is replaced by `clearOutput(id:)`, which stores the current file size in `outputClearOffset` and never truncates.
- Verify: `$T -only-testing:GhastTests/RunnerWrapperTests -only-testing:GhastTests/RunnerServiceTests -only-testing:GhastTests/ConcurrentRunnerOperationsTests`. Commit: `🐛 Propagate runner exit codes and track process state`.

### 1.9 Incremental tailing and activity store [L]
- Test first, extend `LogTailerTests` and add a new `RunnerActivityStoreTests`, both on temp files:
  - appends deliver only the new bytes
  - truncation or replacement restarts from 0
  - activity per runner updates on append
  - lines before `outputClearOffset` are hidden from `lines` but still count for Jobs Today
  - `liveEvents` emits job ends and exits parsed **after** the initial catch-up only
- `LogTailer` switches to offset reads (add `.delete`/`.rename` to the source mask and reopen). New `RunnerActivityStore` (`@Observable`) keeps one tailer per local runner, always on (needed by the sidebar and menu bar).
- Verify: `$T -only-testing:GhastTests/LogTailerTests -only-testing:GhastTests/RunnerActivityStoreTests`. Commit: `✨ Incremental output tailing per runner`.

### 1.10 Display status [L]
- Test first, `RunnerDisplayStatusTests` (parameterized): process state × activity gives the status, header title, secondary line, sidebar subtitle, stat set (Uptime vs Last Run), toolbar actions, error hint and VoiceOver string. Remote online, busy and offline, using the PNG copy above. Remote OS string ("Linux X64").
- New `Ghast/Models/RunnerDisplayStatus.swift`.
- Verify: `$T -only-testing:GhastTests/RunnerDisplayStatusTests`. Commit: `✨ Single runner status model`.

### 1.11 Catalog merge [L]
- Test first, `RunnerCatalogTests`:
  - same scope and name merges, case-insensitively, and the GitHub runner enriches the local item (id, labels)
  - a different scope stays separate
  - a failed scope keeps its last good list and sets the stale flag with its time
  - ordering by name, case-insensitive
  - empty sections
- New `RunnerItem`, `RemoteFetch` and `RunnerCatalog.merge`.
- Verify: `$T -only-testing:GhastTests/RunnerCatalogTests`. Commit: `✨ Merge local and GitHub runners`.

### 1.12 Settings model [L]
- Test first, `AppSettingsTests`: defaults, and persistence through an injected `UserDefaults`.
- New `AppSettings` (`@Observable`), added to `AppDependencies`.
- Verify: `$T -only-testing:GhastTests/AppSettingsTests`. Commit: `✨ AppSettings`.

### 1.13 Design tokens and full fixture data [M]
- `Ghast/Design/FocusMetrics.swift` and `FocusType.swift` take the spec table values plus the values measured from the PNGs: `configurationMaxWidth`, the env name column, and `statusDotHeader`.
- `FixtureDependencies` writes the five runners from the kit. Runner folders get the dionysus-xcode log, a plausible dionysus-arm64 log, and the ghast-release log copied from ErrorRunner.png. Process states are seeded through a fake `RunnerProcessLauncher`, so the **real** parser and catalog build the fixture state. Remote runners come from `FixtureGitHubAPIService`.
- Test first, `FixtureDataTests`: the catalog built from the fixture gives exactly the kit's statuses, subtitles, 5 / 2 jobs today, and Last Run 1 h 02 min.
- Verify: `$T -only-testing:GhastTests/FixtureDataTests -only-testing:GhastTests/FixtureSafetyTests`. Commit: `🧪 Fixture data from the design kit`.

### 1.14 PR gate
- Full suite with `heavy $T`. Fresh `review.concurrency` of `git diff main...HEAD`, because the process lifecycle and persistence changed.
- No visible UI change apart from the OS bump.

---

## PR 2 · Main window (brief: `implement.design`, high; logic steps first, test-first)

### 2.1 Refresh scheduler and rate limits [L]
- Test first:
  - `RefreshSchedulerTests` with the injected clock: launch fetch; activation at most every 15 s; 60 s while visible; no polling while hidden or occluded; backoff 60 → 120 → 240 → 600 that resets on success; skips until `Retry-After`, or `X-RateLimit-Reset` when remaining is 0 (403 and 429 alike).
  - Request tests for the header parsing in `GitHubAPIService.perform`: errors carry `retryAfter` / `rateLimitReset`.
  - A 403 or 404 on an org records it as "Needs owner access".
- New `RemoteRunnerStore` (scopes = admin orgs ∪ scopes of local runners) feeding `RunnerCatalog`.
- Verify: `$T -only-testing:GhastTests/RefreshSchedulerTests -only-testing:GhastTests/GitHubAPIServiceRequestTests`.

### 2.2 Selection [L]
- Test first, `MainSelectionTests`: `MainSelection.resolve` falls back to the next local runner, then the first remote runner, then the empty state. No local runners always gives `.thisMacEmpty`.
- `DetailTab` and `@SceneStorage`.

### 2.3 Output interaction model [L]
- Test first, `OutputViewModelTests`:
  - find: case-insensitive ranges, match count, next and previous with wrap-around
  - follow: on by default, scrolling up turns it off, Follow or ⌥⌘↓ turns it back on
  - copy-all text
  - clear writes the offset
- Pure `OutputFindModel` and `FollowState`.

### 2.4 Scene and shell [V]
- `Window("Ghast", id: "main")` replaces `WindowGroup`. When signed in, it shows `FocusMainView`. Signed-out users still get the old `WelcomeView` until PR 3.
- `NavigationSplitView` with title and subtitle rules and window sizes from `FocusMetrics`.
- The old `MainAppView` becomes unreachable (deleted in PR 5).

### 2.5 Sidebar [V]
- `RunnerSidebar`, `RunnerRow`, `StatusDot`, the "No runners yet" row, the stale marker and tooltip, and the context menus.
- Reconfigure… and Remove… appear disabled until PR 3.

### 2.6 Status header [V]
- `RunnerStatusHeader`, `StatStack`, `LabelTokens` (a wrapping `Layout`) and the inline action row in PNG order.
- Times refresh through `TimelineView(.periodic(by: 30))` on the injected clock.

### 2.7 Output tab [V]
- `RunnerOutputView`: the header buttons, `OutputLineRow` glyphs per the PNG reconciliation, the live line and cursor (Reduce Motion aware), the find bar, ⌘F / ⌘G / ⇧⌘G / Esc, text selection, and the empty message.

### 2.8 Configuration tab [V] + [L]
- Test first, `EnvironmentVariableValidationTests`: names match `^[A-Za-z_][A-Za-z0-9_]*$`, are unique, and invalid rows are not saved. The 0.5 s debounce runs on the injected clock.
- `RunnerConfigurationView` follows Configuration.png. Edits go through the existing env and script writers. The "Restart the runner to apply changes." footer shows while the runner is running.

### 2.9 Remote, error, stopped, starting and empty states [V]
- Remote detail follows RemoteRunner.png, with the ellipsis menu and Open on GitHub URLs.
- `ThisMacEmptyView` follows FirstRun.png.

### 2.10 Toolbar, menu commands, shortcuts [V]
- Native glass groups with `ToolbarSpacer(.fixed)`.
- Runner and View menus via `@FocusedValue`, with every shortcut from the spec table. Commands disable when they don't apply.
- The `+` button and ⌘N open the existing `NewRunnerFlowView` as a stopgap until PR 3.

### 2.11 Lock and log [V]
- `FocusMainSnapshotTests` builds from `FixtureDependencies` and is parameterized over running, idle, stopped, starting, error, remote, empty and configuration, in light and dark. Appearance is forced on the hosting view.
- Capture and compare `main`, `configuration`, `remote`, `error` and `first-run`, light and dark. Fill in `fidelity.md`.
- Verify:
  - `xcodegen && $T -only-testing:GhastTests/RefreshSchedulerTests -only-testing:GhastTests/MainSelectionTests -only-testing:GhastTests/OutputViewModelTests -only-testing:GhastTests/EnvironmentVariableValidationTests -only-testing:GhastTests/FocusMainSnapshotTests`
  - `for s in main configuration remote error first-run; do $F/capture.sh $s && $F/capture.sh $s --dark && $F/compare.sh $s && $F/compare.sh $s --dark; done`
- Gate: full suite with `heavy $T`; the orchestrator posts the side-by-sides; then `review`.

---

## PR 3 · Flows (brief: `implement.design`, high; 3.1–3.4 first, test-first; review with `review.concurrency`)

> **Note from PR 2 review:** when Runner › Remove Runner… (⌘⌫) is enabled, it must not fire while a text field or text view has focus, where ⌘⌫ deletes to the start of the line. Disable the command (or let the key pass through) whenever the first responder is a text input, and check it in the running app in the environment-variable fields and the job-script editor.

### 3.1 New Runner rules [L]
- Test first, `NewRunnerNameTests`:
  - suggested `{host}-{n}` with n = local count + 1, bumped until unique in the scope
  - clash message
  - Create enabled only when the name is valid and a scope is chosen
- Test first, `LabelTokenTests`:
  - fixed defaults per architecture (`ARM64`/`X64`)
  - Return or comma commits a token
  - duplicates and whitespace rejected
  - removing a custom token

### 3.2 API and config arguments [L]
- Request test: `fetchRunnerGroups(org:)` hits `GET /orgs/{org}/actions/runner-groups`.
- Extend `RunnerService.configArguments` with `--runnergroup`, `--work` and `--replace`.
- New `removeArguments(token:)` for `config.sh remove --token`.

### 3.3 Setup flow state machine [L]
- Test first, `RunnerSetupFlowTests`:
  - steps advance in order: download (byte progress via an injected `RunnerDownloader`), register, start, listen
  - a failure marks only that step and Done becomes Try Again
  - the 60 s connect timeout on the injected clock fails step 3 with "The runner didn't connect to GitHub."
  - Cancel after registration unregisters and trashes the folder through `FileTrasher`; Cancel before registration only trashes
- `RunnerService.createManagedRunner` is driven by the flow.

### 3.4 Remove, Remove from GitHub, Reconfigure [L]
- Test first, `RemoveRunnerTests`:
  - order: stop → removal token → `config.sh remove`, falling back to `DELETE` by id → trash → drop from list
  - a GitHub failure surfaces `.needsLocalOnlyConfirmation(reason)`, and nothing is trashed until confirmed
- Test first, `ReconfigureTests`: stop → new token → `--replace` with the same name, labels, group and work folder → start.

### 3.5 Welcome and device code windows [V]
- `Window("Welcome to Ghast", id: "welcome")` with a hidden title bar, sized 560 × 520.
- `WelcomeView` and the device code view with the PNG footer bar.
- Auth changes open and dismiss `main` and `welcome`. Copy and open still happen once per attempt (`DeviceFlowPresenter`).

### 3.6 New Runner sheet [V]
- `NewRunnerConfigureView` with the Add to picker (orgs, repos, and the admin:org note plus "Grant Access in Settings…"), `LabelTokenField`, and the Advanced group.
- `NewRunnerProgressView` with `SetupStepRow`s.
- Replace the PR 2 stopgap. Done selects the new runner on the Output tab.

### 3.7 Alerts and wiring [V]
- Remove and Reconfigure confirmations and the second "Remove from This Mac Only" alert.
- Enable the context-menu and menu items left disabled in PR 2.

### 3.8 Lock and log [V]
- Snapshots: welcome, welcome-failed, device-code, new-runner, new-runner-progress, in light and dark.
- Capture and compare `welcome`, `device-code`, `new-runner`, `new-runner-progress`. Sheet position differences go in the native-difference log.
- Verify: `$T -only-testing:GhastTests/NewRunnerNameTests -only-testing:GhastTests/LabelTokenTests -only-testing:GhastTests/RunnerSetupFlowTests -only-testing:GhastTests/RemoveRunnerTests -only-testing:GhastTests/ReconfigureTests -only-testing:GhastTests/GitHubAPIServiceRequestTests -only-testing:GhastTests/FocusFlowSnapshotTests`, plus the capture loop for those 4 screens.
- Gate: full suite with `heavy $T`. Evan does one live round trip (Owner action C).

### PR 3 accepted risks (review.concurrency, round 1)
Recorded here instead of fixed; each is unlikely in normal use, or predates this PR.
- **config.sh exits non-zero after GitHub registered the runner.** The flow treats the step as failed and offers Try Again or Cancel. No local runner was recorded (`runnerID` is nil), so Cancel only moves the folder to the Trash and does not unregister. The runner stays registered on GitHub until Remove from GitHub on its remote row cleans it up.
- **Leftover `.setup-*` / `.reconfigure-*` folder after a quit or crash mid-flow.** These are hidden and harmless. A later setup never reuses them. A `.reconfigure-*` folder holds the old registration files, so it's worth checking by hand if a reconfigure was interrupted.
- **404 treated as already gone in `deleteByID`.** A 404 caused by a wrong scope would read as success. The id and scope both come from GitHub's own listing, so this needs a stale row.
- **Registration and removal tokens are visible in `config.sh` argv** (`ps`) while it runs. This predates PR 3. Follow-up: pass tokens via env. The runner already reads `ACTIONS_RUNNER_INPUT_TOKEN`.
- **A hung `config.sh` blocks Cancel.** Cancel waits for config.sh because its result must be recorded. A hang means the sheet stays on Cancelling until the process exits. Follow-up: a timeout that stops the script and reports it.

---

## PR 4 · Settings and background (brief: `implement.design`, high; 4.1–4.3 first, test-first)

### 4.1 Restart at launch [L]
- Test first, `RestartAtLaunchTests`:
  - starts every runner with `shouldBeRunning`, one at a time, 1 s apart on the injected sleeper
  - a start failure becomes `.error`
  - nothing starts when the setting is off

### 4.2 Notifications [L]
- Test first, `NotificationPolicyTests`:
  - an unexpected exit notifies (default on)
  - requested stops, quit, sign-out and exit-0/2 restarts never notify
  - job failure notifies only when opted in
  - only `liveEvents` notify, never the backlog
  - permission is asked once, on the first post or the first time a notify toggle is switched on
  - denied permission stays silent
- `NotificationService` sits over a `UNUserNotificationCenter` protocol. A click selects the runner, opens the Output tab and scrolls to the end.

### 4.3 Login item and updates [L]
- Test first:
  - `LoginItemTests`: maps `SMAppService` status (enabled / requiresApproval / notRegistered) through a protocol fake.
  - `UpdateStatusTests`: Checking / Up to date / Update available / Last checked / Never checked, from a fake updater protocol over `SPUUpdater` and the delegate callbacks.
- Check Now uses a background check.

### 4.4 Settings window [V]
- `Settings { TabView }`, General and Account per Settings.png.
- The Grant… sheet reuses the device-code view. Add the "Needs owner access" note and the sign-out confirmation.

### 4.5 Menu bar extra [L] + [V]
- Test first, `MenuBarMenuModelTests`: a pure description of the items, badges (Idle / Running / Connecting / Stopped / Exited), submenus, the enabled state of Start All and Stop All, the signed-out state, and the "No runners on this Mac" item.
- `MenuBarController` (`NSStatusItem` + `NSMenu`, `NSMenuItem.badge`, coloured non-template dot images) is rebuilt on status change and toggled by `AppSettings`. Dock policy stays `.regular`, as Evan decided.

### 4.6 Fixture `menu-bar` [V]
- The fixture opens the status menu with dionysus-xcode highlighted and its submenu open. Capture with a region capture.
- The notification banner is native chrome and is logged as a difference.

### 4.7 Release metadata [M]
- Set `sparkle:minimumSystemVersion` in `appcast-template.xml` to 26.0.

### 4.8 Lock and log [V]
- Snapshots: settings-general, settings-account, account-not-granted, light and dark.
- Capture and compare `settings-general`, `settings-account`, `menu-bar`.
- Verify: `$T -only-testing:GhastTests/RestartAtLaunchTests -only-testing:GhastTests/NotificationPolicyTests -only-testing:GhastTests/LoginItemTests -only-testing:GhastTests/UpdateStatusTests -only-testing:GhastTests/MenuBarMenuModelTests -only-testing:GhastTests/FocusSettingsSnapshotTests`, plus the capture loop.
- Gate: full suite with `heavy $T`. The orchestrator checks open-at-login and notifications on a release-signed build through `xcode-remote` (risk 6).

---

## PR 5 · Cleanup (brief: `implement`, medium)

### 5.1 Delete the old UI [M]
Delete these views and their snapshot tests and folders:
- `DashboardView` (StatCard, ModernRepositoryCard, DashboardRepositoryCard)
- `RepositoryDetailView`, `OrganizationDetailView`, `ScopedRunnersPanel`
- `SidebarView`, `SettingsView`
- `ScopeUpgradeBanner` and `ReSignInSheet`
- `LocalRunnersView`, `RunnerLogsView`, the old `RunnerConfigurationView`
- `AddRunnerView`, `NewRunnerFlowView`
- `RunnerStats`, `RunnerStatus`, `AppState.SelectedView`
- the dashboard-only API calls

Delete these test suites: Dashboard, RepositoryDetail, OrganizationDetail, Sidebar, Settings, ScopeUpgradeBanner, StatCard, SimpleSnapshotTest, RepositoryCard, LocalRunners, RunnerLogs, the old RunnerConfiguration, AddRunner, NewRunnerFlow, RunnerStats and SplitViewFrame. Keep any suite that still covers live code.

### 5.2 Docs [M]
- Update CLAUDE.md: architecture, fixture mode, the fidelity scripts, and the macOS 26 / Xcode 27 requirement.

### 5.3 Full recapture [V-run]
- Recapture all 12 screens in light and dark, and finish `fidelity.md` so every deviation is either fixed or logged.

### 5.4 Gate
- `xcodegen && heavy $T`.
- Run `DEVELOPER_DIR=/Applications/Xcode-26.5.0.app/Contents/Developer $B` if CI stays on Xcode 26.x.
- Fresh `review` of the PR.
- Evan spot-checks a capture on a macOS 26 machine before release (owner action D).

---

## Owner actions and calls (Evan)
- **A. Screen Recording grant.** Add the process step 1.1 names under System Settings › Privacy & Security › Screen & System Audio Recording on Dionysus (via PiKVM). Without it, no capture works.
- **B. Virtual HiDPI display on Dionysus.** Approve a dev-only helper in `Scripts/fidelity/` that uses the private `CGVirtualDisplay` SPI. It is never shipped and runs only during captures, though it briefly adds a display to the PiKVM desktop. The alternative is installing DeskPad or BetterDisplay. Recommended: the helper, because it needs no install. If neither is acceptable, captures move to his Retina laptop by hand, which breaks the agent loop.
- **C. Live round trip after PR 3.** Create, then remove, one org runner and one repo runner.
- **D. macOS 26 spot-check before release.** Look at one capture on a macOS 26 machine (spec risk 4).
- **Veto window.** The "Defaults not drawn" list in PNG reconciliation (remote busy and offline lines, the generic error hint), and dropping the visible "Runner exited with code N" line to match ErrorRunner.png.

## Risks
1. Capture (spec risk 1) is now concrete: Screen Recording is denied and the host display is 1x. Step 1.1 gates everything after it.
2. Glass may differ between off-screen snapshot hosting, macOS 27 on the build host, and macOS 26 on users' Macs. Snapshots lock layout only; window captures and owner action D cover glass.
3. Ad-hoc Debug signing can make `SMAppService` and notification authorization behave differently from notarized builds. PR 4 verifies on a release-signed build.
4. The `CGVirtualDisplay` SPI can break across macOS updates. It is dev-only; the fallback is laptop capture.
5. The wrapper change (1.8) only reaches runners after a restart. The legacy `HH:MM:SS` parsing covers runners still on the old wrapper, and they report Jobs Today as 0 until they restart.
6. Activity tailing for every local runner stays on all the time, and logs aren't rotated (out of scope). Large logs make the initial catch-up slow; the parser keeps only 5,000 lines but reads the whole file once.
7. Whether the CI image `macos-26` ships Xcode 27 is unknown. Step 1.2 checks; step 5.4 builds with 26.5 if CI stays on 26.x.
8. Remove, Cancel-during-setup and Reconfigure unregister runners on GitHub, which can't be undone. Each runs behind a confirmation, folders go to the Trash and are never deleted, and PR 3 is reviewed with `review.concurrency`.
