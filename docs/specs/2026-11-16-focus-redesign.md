# Focus redesign

Status: draft 2026-11-16 (direction approved: "1 · Focus")

Design source: `docs/design/focus-redesign/kit.md` and the PNGs beside it
(`Main`, `FirstRun`, `NewRunner`, `Welcome`, `Settings`, `MenuBar`, each with a
`-dark` twin; `Configuration`, `RemoteRunner`, `ErrorRunner` are being drawn).
Library and Monitor in the kit are rejected; ignore them.

Precedence when sources disagree: **PNG > kit.md prose > this spec's
descriptions**. Screens specced here from descriptions only (Configuration,
remote runner, error runner) are provisional on layout and copy until their
PNGs land; the behaviour rules still hold.

## Goal
Rebuild Ghast's UI so it matches the Focus mockups: one window whose sidebar
lists the runners themselves (This Mac, Other Machines), a detail pane with
live Output and Configuration, compact sign-in windows, a New Runner sheet, a
standard Settings window, a menu bar extra and crash notifications. "Matches"
means a fixture build captured at 2x is indistinguishable from the PNGs except
for listed native-control differences (see Fidelity protocol).

## Non-goals
- Library and Monitor layouts, stat-card dashboards, per-repository pages.
- Editing a runner's name, scope or labels after creation (GitHub label edits
  need extra API work; Configuration shows them read-only).
- Output or control for runners on other machines (status only).
- Enterprise runners, ephemeral/JIT runners, log rotation, multiple windows.
- iOS/iPadOS, Mac Catalyst. macOS 15 support (dropped; see Risks).

## Decisions (settled)
- Minimum macOS **26.0**, built with Xcode 27. `project.yml` deployment target
  and `LSMinimumSystemVersion` become 26.0.
- Standard SwiftUI/AppKit controls and system Liquid Glass. Custom glass only
  where the mockup needs it and no standard control exists (expected: none in
  the main window; the toolbar, sidebar and menus are native).
- Delete: Dashboard, repository and organization detail pages, sidebar repo
  list, Settings *page*, `ScopeUpgradeBanner`, `RunnerStats`, stat cards. The
  `admin:org` grant moves to Settings › Account › Permissions and a note in
  New Runner's "Add to" picker.
- One status vocabulary, one meaning per colour, always paired with words.

## Information architecture

```
Welcome window (signed out) ── Device code state
Main window (signed in)
├─ Sidebar
│  ├─ This Mac         local runners (or "No runners yet")
│  └─ Other Machines   GitHub runners not on this Mac (hidden when empty)
└─ Detail
   ├─ Local runner:  [Output | Configuration]
   ├─ Remote runner: status only
   └─ This Mac empty state
New Runner sheet ── Configure → Setting up
Settings window (⌘,) ── General | Account
Menu bar extra (toggleable) ── per-runner submenus
Notifications ── unexpected stop, job failure (opt-in)
```

Scenes (`GhastApp`): `Window("Ghast", id: "main")` (single window, not
`WindowGroup`), `Window("Welcome to Ghast", id: "welcome")`, `Settings`, and an
`NSStatusItem` owned by `MenuBarController`. Signed out: only `welcome` shows.
Sign-in success opens `main` and dismisses `welcome`; sign-out does the reverse.

## Tokens → SwiftUI

Colours resolve to system semantics so light/dark, Increase Contrast and
accent colour work for free. Raw hex from the kit is used only in the design
fixture's desktop backdrop (not shipped).

| Kit token | SwiftUI |
|---|---|
| `--label` / `--label-2` / `--label-3` | `.primary` / `.secondary` / `Color(nsColor: .tertiaryLabelColor)` (non-text only) |
| `--sep` | `Color(nsColor: .separatorColor)` |
| `--fill`, `--sel` | `Color(nsColor: .quaternarySystemFill)`; selection is native `List` selection |
| `--win`, `--win-2` | `Color(nsColor: .windowBackgroundColor)`, `Color(nsColor: .controlBackgroundColor)` |
| `--group` | native `Form` `.formStyle(.grouped)` section background |
| `--accent-fill`, `--accent-ink`, `--accent-soft` | `.tint` / `Color.accentColor`, `.accentColor`, `.accentColor.opacity(0.12)` |
| `--green` `--orange` `--red` | `Color.green`, `.orange`, `.red` (system) |
| `--glass`, `--sidebar`, `--menu` | system Liquid Glass via native toolbar, sidebar, menus |
| `--font`, `--mono` | system font; `.monospaced()` (SF Mono) |

Type: kit text styles map to `Font` constants in `FocusType` (Large Title 26/32
bold, Title 1 22 bold, Title 2 17 semibold, Title 3 15 semibold, Headline 13
semibold, Body 13, Callout 12, Subheadline 11, Footnote 10, Output mono 12 with
19 pt line height). Nothing below 10 pt.

Sizes live in `enum FocusMetrics` (one file, named constants, no literals in
views). Values from the kit:

| Constant | Value |
|---|---|
| `mainWindowSize` | 1240 × 780 (default), min 900 × 560 |
| `sidebarWidth` | 248 (min 220, max 320) |
| `contentInset` | 32 horizontal |
| `statusDot` / `statusDotHeader` | 8 / 10 (header value to confirm on capture) |
| `runningHalo` | 3 pt ring, orange at 22% |
| `runnerRowPadding` | 7 v × 8 h, radius 10 |
| `tokenHeight` | 20, padding 7 h, radius 6, Subheadline weight 500 |
| `outputLine` | 19; time column 64; glyph column 16 |
| `liveLine` | 24 high, radius 6, inset −8 h |
| `welcomeWindow` | 560 × 520 |
| `appIconLarge` / `appIconBanner` | 96 (radius 22) / 32 |
| `deviceCode` | mono 34 semibold, tracking 0.08 em, padding 16 × 28, radius 12 |
| `sheetWidth` | 500, padding 24 |
| `settingsWidth` | 620; content padding 20 × 28 |
| `accountAvatar` | 64, initials 24 semibold |
| `emptyStateGlyph` | 56; body max width 380 |

## Status model

`RunnerDisplayStatus` is the single source for dot, words and VoiceOver:

| Status | Dot | Header (Title 2) | Sidebar subtitle |
|---|---|---|---|
| `.idle` | filled green | "Idle" | `Idle · {scope}` |
| `.runningJob(name, since)` | filled orange + halo | "Running a job" | `Running {name}` |
| `.starting` | hollow ring + 12 pt `ProgressView` in header | "Connecting…" | `Connecting…` |
| `.stopped(at)` | hollow ring | "Stopped" | `Stopped · {scope}` |
| `.error(code, at)` | filled red | "Exited with code {n}" | `Exited with code {n}` |
| `.offline` (remote) | hollow ring | "Offline" | `Offline · {scope}` |
| `.remoteBusy` (remote) | orange + halo | "Running a job" | `Running a job · {scope}` |

`{scope}` is the org login or repo full name. `.starting` is not in the
mockups; it reuses the Stopped ring so no new colour meaning is added.

Derivation (pure function, `RunnerDisplayStatus.make`):
- Local: process state decides stopped / starting / error; while the process
  runs, the output parser decides idle vs running job. `.starting` lasts from
  launch until the parser sees "Listening for Jobs".
- Remote: GitHub `status == "online"` → `busy ? .remoteBusy : .idle`; anything
  else → `.offline`.
- A local runner never takes status from GitHub; GitHub only enriches it (id
  for removal, authoritative label list).

## Screens

### Main window: chrome
- `NavigationSplitView` with native floating sidebar; `.navigationTitle` =
  selection name, `.navigationSubtitle` = `{scope} · This Mac` / `{scope} ·
  Other Machine` / host name for the empty state. Title is never "Ghast".
- Toolbar (`.toolbar`, native glass groups, `ToolbarSpacer(.fixed)` between
  groups):
  - `.principal`: `Picker` `.segmented` "Output | Configuration" (local runners only).
  - Trailing group 1 (local): running/starting → `stop.fill` "Stop",
    `arrow.clockwise` "Restart"; stopped/error → `play.fill` "Start".
    Remote → `Menu` with `ellipsis` (see Remote runner).
  - Trailing group 2: `plus` "New Runner".
  - Icon-only buttons carry `.help` tooltips and accessibility labels.

### Sidebar (`RunnerSidebar`)
- `List(selection:)` `.listStyle(.sidebar)`, sections "This Mac" and "Other
  Machines" (title case headers, native styling).
- Row `RunnerRow`: `StatusDot` + VStack(name Body weight 500, subtitle
  Subheadline `.secondary`). Two lines always.
- This Mac with no runners: one non-selectable row "No runners yet" (Callout
  `.secondary`, no dot).
- Other Machines hidden when empty or signed out. While a fetch has failed and
  stale data shows, the header gets a trailing `exclamationmark.triangle`
  (`.secondary`) with tooltip "Couldn't reach GitHub. Showing runners as of
  {time}."
- Ordering: by name, case-insensitive, within each section.
- Selection persists across launches (`@SceneStorage`, runner id). If the
  selected runner disappears, select the next local runner, else the first
  remote runner, else show the empty state.
- Context menus:
  - Local: Start / Stop / Restart (as applicable) · Show Output · Show
    Configuration · Show in Finder · Copy Name · — · Reconfigure… · Remove Runner…
  - Remote: Open on GitHub · Copy Name · — · Remove from GitHub…
  - "This Mac" header: New Runner… · Start All Runners · Stop All Runners.

### Detail: status header (`RunnerStatusHeader`)
Padding 0 × 32 under the toolbar (content top ≈ 64).
- Leading: `StatusDot` (header size) + status title (Title 2); below it a Body
  `.secondary` line:
  - running: `{job} · started {n} min ago` (nearest minute; < 1 min = "started
    just now"); idle: `Waiting for jobs`; stopped: `Stopped at {time}` or
    `Not started yet`; error: `Stopped unexpectedly at {time}`; starting:
    `Connecting to GitHub…`.
- Error and stopped only: inline row under that line, `Button("Start Runner")`
  `.borderedProminent` + (error only) `Button("Reconfigure…")` `.bordered`,
  both `.controlSize(.regular)` capsule.
- Trailing: `StatStack`s separated by 1 pt vertical separators: Uptime
  ("3 h 14 min"; "—" when not running), Jobs Today, Version. Subheadline
  `.secondary` label over Body value.
- Below: `LabelTokens` (wrapping `Layout`), then a full-width separator.
- Times refresh through `TimelineView(.periodic(by: 30))` driven by the
  injected clock.

### Detail: Output tab (`RunnerOutputView`)
- Header row: "Output" (Headline) + borderless icon buttons, trailing: Follow
  (`arrow.down.to.line`, accent when on), Find (`magnifyingglass`), Copy
  (`doc.on.doc`, copies all visible output), Clear (`trash`).
- Lines: `ScrollView` + `LazyVStack` of `OutputLineRow`: time (mono 12,
  `.secondary`, 64 wide), glyph column (16), text (mono 12, `.primary`).
  Glyphs: connected `checkmark` green; job start `play.fill` orange; succeeded
  `checkmark.circle.fill` green; failed `xmark.circle.fill` red; error lines
  have no glyph and red text.
- Live line: while a job runs, the last line sits on a `quaternarySystemFill`
  rounded rect (`liveLine`) with a static block cursor (7 × 14, tertiary).
  Cursor blink only when Reduce Motion is off.
- Follow: on by default; scrolling up turns it off; Follow or ⌥⌘↓ turns it
  back on and jumps to the end.
- Find: inline find bar above the lines (`TextField`, match count, ‹ › buttons,
  Done); matches highlighted with accent at 25%; ⌘F, ⌘G, ⇧⌘G, Esc.
- Text is selectable (`.textSelection(.enabled)`); ⌘C copies the selection.
- Clear hides everything before the clear point (stored per runner as a log
  byte offset); the file is untouched so Jobs Today stays correct.
- Empty output: centered Callout `.secondary` "No output yet. Start the runner
  to see its output."

### Detail: Configuration tab (`RunnerConfigurationView`, provisional until Configuration.png)
`ScrollView` with `Form` `.formStyle(.grouped)`:
1. **Runner**: Name; Scope (`blackpaw-studio · Organization`); Labels
   (tokens, read-only); Version; Folder (`~/.ghast/runners/{name}`, mono 12
   `.secondary`) + `Button("Show in Finder")`.
2. **Environment Variables**: rows of NAME / value `TextField`s (mono 12);
   `+` / `−` control below the list (System Settings style). Help: "Applied
   the next time the runner starts." Names must match
   `^[A-Za-z_][A-Za-z0-9_]*$` and be unique; an invalid row gets a red field
   border and is not saved.
3. **Job Scripts**: `Toggle("Run a script before each job")` and
   `Toggle("Run a script after each job")`; each, when on, shows a mono
   `TextEditor` (min height 120). Help: "Scripts run with bash in the
   runner's work folder."
4. `Button("Remove Runner…", role: .destructive)`, leading, below the form.
- Edits save on field commit and debounce (0.5 s) through `RunnerService`'s
  existing env/script writers. If the runner is running, a footer note reads
  "Restart the runner to apply changes." with a Restart button.

### Remote runner (provisional until RemoteRunner.png)
- No segmented control, no Start/Stop. Toolbar group 1 is an `ellipsis`
  `Menu`: Open on GitHub · Copy Name · — · Remove from GitHub….
- Status header as above (no stats, no inline buttons), labels, separator.
- Below: a quiet centered note, Headline "Output Is on That Machine" over
  Callout `.secondary` "GitHub reports this runner's status. Its output stays
  on the machine that runs it."
- Open on GitHub URLs: org
  `https://github.com/organizations/{org}/settings/actions/runners/{id}`,
  repo `https://github.com/{owner}/{repo}/settings/actions/runners/{id}`.

### Error runner (provisional until ErrorRunner.png)
Header red dot, "Exited with code 1", "Stopped unexpectedly at 10:05 AM",
inline Start Runner / Reconfigure…. Output keeps the last run's lines; error
lines render red; the final line is Ghast's own "Runner exited with code 1".

### This Mac empty state (`ThisMacEmptyView`, FirstRun.png)
Title "This Mac", subtitle host name ("Dionysus"). Centered:
`laptopcomputer.badge.plus`-style glyph 56 `.secondary` (custom symbol if the
system set lacks it), "No Runners on This Mac" (Title 1), body (max 380):
"Create a runner for a repository or organization. Ghast downloads the
official GitHub runner, registers it, and starts it for you.",
`Button("New Runner…")` `.borderedProminent`, then a `.link` button "About
Self-Hosted Runners" opening GitHub's self-hosted runner docs.

### Welcome window (Welcome.png, left)
560 × 520, `.windowStyle(.hiddenTitleBar)`, `.windowResizability(.contentSize)`,
no toolbar. Centered column: app icon 96, "Welcome to Ghast" (Large Title),
"Run GitHub Actions jobs on this Mac." (Title 3 regular `.secondary`), three
`FeatureRow`s in a 380 column (32 pt accent glyph + Headline + Callout
`.secondary`; copy per kit), `Button("Sign In with GitHub")`
`.borderedProminent .controlSize(.large)`, footnote "Ghast asks for access to
your repositories and organization runners."
Failure (`signInState.failed`): Callout red message under the button; the
button reads "Try Again".

### Device code (Welcome.png, right)
Same window. `key` glyph 32 accent, "Enter This Code on GitHub" (Title 1),
body (max 400) "Ghast opened github.com/login/device in your browser. Enter
this code there to finish signing in.", `DeviceCodeBox` ("WDJB-MJHT"),
`Button("Copy Code")` `.bordered` + `Button("Open GitHub")`
`.borderedProminent`. Footer bar (per PNG, not kit prose): top separator,
leading small `ProgressView` + "Waiting for you to approve…" (Callout
`.secondary`), trailing `Button("Cancel")`. Copy and open happen once per
attempt (existing behaviour).

### New Runner sheet (NewRunner.png)
`.sheet` on the main window, width 500, one sheet with two states.

**Configure** (`NewRunnerConfigureView`): "New Runner" (Title 2), Body
`.secondary` "Ghast downloads the GitHub Actions runner, registers it, and
starts it on this Mac." `Form` `.grouped`:
- **Add to**: `Picker` `.menu`; label shows 16 pt avatar + name + `.secondary`
  kind ("Organization" / "Repository"). Sections Organizations (admin orgs)
  and Repositories (repos with `permissions.admin`). Without `admin:org`, the
  menu ends with a disabled note "Organizations need more access" and an item
  "Grant Access in Settings…".
- **Name**: `TextField`, focused on appear, suggested `{host}-{n}` where n =
  local runner count + 1, bumped until unique in the scope.
- **Labels**: `LabelTokenField`: fixed default tokens (`self-hosted`,
  `macOS`, `ARM64`/`X64` per architecture), removable custom tokens with ×,
  trailing borderless `TextField` "Add Label"; Return or comma commits;
  duplicates and whitespace rejected.
- Help: "Names must be unique in {scope}. Default labels are added for you."
- `DisclosureGroup("Advanced")` with `.secondary` summary "Architecture,
  runner group, work folder": Architecture picker (host arch default; X64
  notes Rosetta), Runner group picker (orgs only, from
  `GET /orgs/{org}/actions/runner-groups`, default "Default"), Work folder
  `TextField` (default `_work`).
- Footer: Cancel (`.cancelAction`), Create Runner (`.defaultAction`,
  `.borderedProminent`; disabled until name valid and scope chosen).
- Name clash (from the scope's runner list): inline red Callout "A runner
  named {name} already exists in {scope}."

**Setting up** (`NewRunnerProgressView`): "Setting Up {name}" (Title 2),
grouped box of 44 pt `SetupStepRow`s: Download runner {version} (trailing
size, "34 of 182 MB" while downloading) · Register with {scope} · Start
runner (trailing "Connecting to GitHub…") · Listen for jobs. Icons: done
green `checkmark.circle.fill`; current small `ProgressView`; pending
`circle` tertiary; failed red `xmark.circle.fill` with the error as the row's
secondary line. Footer: Cancel + Done (`.borderedProminent`, disabled until
"Listen for jobs" completes). On failure Done becomes "Try Again".
- Cancel stops work, unregisters if registration completed, moves the
  partial folder to the Trash.
- Connect timeout: 60 s without "Listening for Jobs" fails step 3 with "The
  runner didn't connect to GitHub."
- Done dismisses and selects the new runner (Output tab).

### Settings window (Settings.png)
`Settings { TabView }` with native toolbar tabs: General (`gearshape`),
Account (`person.crop.circle`). Width 620; height fits content.

**General** (`Form .grouped`):
- Startup: "Open Ghast at login" (`SMAppService.mainApp`; reflects actual
  status; `.requiresApproval` shows help "Allow Ghast in System Settings ›
  General › Login Items." + Open button) · "Restart runners that were running
  when Ghast quit" (default on).
- Menu Bar & Notifications: "Show Ghast in the menu bar" (default on) ·
  "Notify when a runner stops unexpectedly" (default on) · "Notify when a job
  fails" (default off). If notifications are denied, help text "Notifications
  for Ghast are off in System Settings." + Open System Settings button.
- Updates: "Check for updates automatically" (binds
  `SPUUpdater.automaticallyChecksForUpdates`) · row "Ghast {version}
  ({build})" with secondary line "Up to date" / "Update available" /
  "Checking…" / "Last checked {relative}" / "Never checked", and
  `Button("Check Now")` (disabled while checking).
- Runners: "Runners folder" value `~/.ghast/runners` (mono 12 `.secondary`) +
  Show in Finder. Help: "Each runner keeps its work files and logs in its own
  folder here."

**Account**: centered 64 pt initials avatar (accent 12% fill, accent text),
name (Title 2), "Signed in to GitHub" (Callout `.secondary`).
- Permissions: Repositories / Organization runners, each trailing green
  `checkmark.circle.fill` + "Granted", or orange `exclamationmark.circle.fill`
  + "Not granted" + `Button("Grant…")`, which runs Device Flow in a sheet
  using the device-code view.
- Organizations You Administer: rows of 16 pt avatar + login; "None" row
  when empty.
- `Button("Sign Out…")` leading, help "Signing out doesn't stop or remove
  runners on this Mac." Confirmation alert before signing out.

### Menu bar extra (MenuBar.png)
`MenuBarController` owns an `NSStatusItem` + `NSMenu` (AppKit: needed for
right-aligned status words via `NSMenuItem.badge` and coloured non-template
dots; SwiftUI `MenuBarExtra(.menu)` can't guarantee either). Template ghost
glyph 16 pt. Rebuilt on status change.
- Section header "This Mac"; per local runner: dot image + name, badge =
  short status (Idle / Running / Connecting / Stopped / Error — see Open
  question 1), submenu: Show Output · — · Restart · Stop (running) or Show
  Output · — · Start (not running).
- — Start All Runners · Stop All Runners (disabled when nothing to do)
- — New Runner… (disabled when signed out) · Open Ghast
- — Settings… ⌘, · Quit Ghast ⌘Q
- No runners: disabled item "No runners on this Mac".
- Submenu side is chosen by the system (mockup shows left; native).

### Notifications
`UNUserNotificationCenter`, category per kind, `userInfo` = runner id.
- Unexpected stop (default on): title "{name} stopped unexpectedly", body "The
  runner exited with code {n}. Click to see its output."
- Job failure (opt-in): title "{job} failed on {name}", body "Click to see its
  output."
- Permission is requested the first time a notification would be posted or a
  notify toggle is switched on, whichever comes first. Denied = silent.
- Click: activate, open `main`, select that runner, Output tab, scroll to end.
- User-initiated stops, quits, sign-outs and runner self-updates (exit 0/2
  restarts) never notify.

## Menu commands and shortcuts

| Menu | Item | Shortcut |
|---|---|---|
| Ghast | Settings… | ⌘, |
| Ghast | Check for Updates… | — |
| File | New Runner… | ⌘N |
| Edit › Find | Find / Find Next / Find Previous | ⌘F / ⌘G / ⇧⌘G |
| View | Output / Configuration | ⌘1 / ⌘2 |
| View | Follow Output | ⌥⌘↓ |
| View | Clear Output | ⌘K |
| View | Show/Hide Sidebar, Full Screen | ⌃⌘S, ⌃⌘F (standard) |
| Runner | Start / Stop / Restart | ⌘R / ⌘. / ⇧⌘R |
| Runner | Start All Runners / Stop All Runners | — |
| Runner | Show in Finder · Open on GitHub · Copy All Output | —, —, ⌥⌘C |
| Runner | Reconfigure… · Remove Runner… | —, ⌘⌫ |
| Window | Ghast (main window) | ⌘0 |
| Help | About Self-Hosted Runners | — |

Runner commands act on the selection (`@FocusedValue`) and disable when not
applicable (remote, wrong state, a sheet is open — so ⌘. still cancels sheets).

## Data model changes
1. `LocalRunner` gains `shouldBeRunning: Bool` (set by Start, cleared by user
   Stop and by an unexpected exit), `lastExit: RunnerExit?` (`code`, `at`),
   `outputClearOffset: UInt64`, `runnerGroup: String?`, `workFolder: String`.
   Decoding old data: missing fields default; legacy `status == "running"`
   maps to `shouldBeRunning = true`; `status` is no longer persisted.
2. `RunnerProcessState` (runtime only): `.stopped`, `.starting(since)`,
   `.running(since)`, `.exited(RunnerExit)`. `RunnerService` publishes
   `processStates: [LocalRunner.ID: RunnerProcessState]`.
3. `RunnerActivity` (parser output): `lines: [OutputLine]` (last 5,000),
   `runnerVersion`, `currentJob: (name, startedAt)?`, `jobs: [JobRecord]`
   (`name`, `result: succeeded|failed|cancelled|other`, `startedAt`,
   `finishedAt?`), `isListening`, `jobsStarted(on: Date, calendar:)`.
4. `OutputLine`: `timestamp: Date?`, `text`, `kind`
   (`connected|jobStarted|jobSucceeded|jobFailed|error|plain`).
5. `RunnerItem` (unified list entry): `id`, `name`, `scope`, `labels`,
   `location: .thisMac(LocalRunner.ID) | .otherMachine(GitHubRunner)`,
   `gitHubRunnerID: Int?`, `status: RunnerDisplayStatus`.
6. `RunnerCatalog.merge(local:, processStates:, activities:, remote:) ->
   (thisMac: [RunnerItem], otherMachines: [RunnerItem])`, pure. Remote input
   is `[RunnerScope: RemoteFetch]` (`.loaded([GitHubRunner], at)`,
   `.failed(error, lastGood?)`). Match: same scope **and** name equal
   case-insensitively → the GitHub runner enriches the local item and is not
   listed under Other Machines. All other remote runners are Other Machines.
7. `AppSettings` (`@Observable`, injected `UserDefaults`):
   `restartRunnersAtLaunch` (true), `showMenuBarExtra` (true),
   `notifyUnexpectedStop` (true), `notifyJobFailure` (false),
   `notificationPermissionRequested`. Open-at-login is read from
   `SMAppService`, never stored.
8. `AppState.SelectedView` is replaced by `MainSelection`
   (`.thisMacEmpty | .runner(RunnerItem.ID)`) and `DetailTab`
   (`.output | .configuration`), both `@SceneStorage`.
9. API additions: `fetchRunnerGroups(org:)`; registration passes
   `--runnergroup` and `--work`; Reconfigure uses `config.sh --replace`.
   Removed: dashboard-only calls and `RunnerStats`.
10. Injected `Clock` (`now()`), `Calendar`, `HostInfo` (computer name), and
    `FileTrasher` (wraps `NSWorkspace.recycle`) so tests and the fixture
    control them.

## Runner process and output rules
1. The wrapper script writes each output line prefixed with local ISO-8601
   (`%Y-%m-%dT%H:%M:%S%z`). The parser also accepts the legacy `HH:MM:SS`
   prefix (date unknown → never counted in Jobs Today).
2. The runner's own `YYYY-MM-DD HH:MM:SSZ: ` prefix is stripped from text;
   blank lines are dropped; the wrapper timestamp is the displayed time.
3. Ghast lifecycle lines use a `ghast:` marker (`ghast: start`,
   `ghast: exit code=N`) and are hidden, except a non-zero exit, shown as the
   error line "Runner exited with code N".
4. The wrapper exits with the runner's exit code (today it always exits 0).
   Exit 0 and 2 still restart inside the wrapper (runner self-update) and are
   not errors.
5. Unexpected exit = the wrapper terminated without a Ghast stop request →
   `lastExit` recorded, `shouldBeRunning` cleared, status `.error`, and the
   unexpected-stop notification. A requested stop → `.stopped(at)`.
6. Parser kinds: `√ Connected to GitHub` → connected; `Current runner
   version: 'x'` → version; `Listening for Jobs` → listening, clears current
   job; `Running job: {name}` → job start; `Job {name} completed with result:
   {result}` → job end; lines starting `Error`, `Failed`, `An error occurred`,
   `Unhandled exception`, or containing `exit with terminated error` → error;
   anything else plain. Partial trailing lines wait for their newline; CRLF
   tolerated.
7. Parsing is incremental from the last byte offset (file watch via
   `LogTailer`); a truncated file restarts from 0.
8. Jobs Today = job starts whose timestamp is today in the local calendar,
   including the running one. Uptime = now − current process start.
9. Duration format: `{h} h {m} min`, `{m} min`, `{d} d {h} h`; "started {n}
   min ago" rounds to the nearest minute.

## Behaviour rules
- **Remote refresh**: scopes = admin orgs ∪ scopes of local runners. Fetch on
  launch, on main window activation (at most every 15 s), after create/remove,
  and every 60 s while the main window is visible. No polling when it's
  hidden or occluded; the menu bar shows only local runners.
- **Errors**: a failed scope keeps its last good list (stale marker on the
  section header); other scopes are unaffected. 403/404 on an org → that org
  is skipped and Settings › Account lists it under a "Needs owner access"
  note. Backoff on repeated failure: 60 → 120 → 240 → 600 s cap; success resets.
- **Rate limits**: honour `Retry-After` and, when `X-RateLimit-Remaining` is
  0, `X-RateLimit-Reset`; skip polls until then. Secondary-limit 403s are
  treated the same.
- **Offline**: same path as errors; local runners and output are unaffected.
- **Signed out**: welcome window; Other Machines and New Runner unavailable;
  local runners keep running and stay controllable from the menu bar.
- **Restart at launch**: when on, start every runner with `shouldBeRunning`
  (covers quit and crash: quitting stops processes but keeps the flag). Starts
  are sequential with 1 s spacing; a failure to start becomes `.error`.
- **Remove Runner**: confirmation alert "Remove “{name}”?" / "Ghast stops the
  runner, removes it from {scope} on GitHub, and moves its folder to the
  Trash." [Remove Runner (destructive)] [Cancel]. Order: stop → removal token
  → `config.sh remove` (falls back to `DELETE` by runner id) → trash folder →
  drop from list. If the GitHub step fails: second alert "Couldn't remove
  {name} from GitHub: {reason}" with [Remove from This Mac Only] [Cancel].
- **Remove from GitHub…** (remote): confirmation, `DELETE` by id, refresh.
- **Reconfigure…**: confirmation "Ghast registers {name} with {scope} again
  using a new token." → stop, new registration token, `config.sh --replace`
  with the same name/labels/group/work folder, start.
- **Empty states**: no local runners → This Mac empty state is the detail
  even when Other Machines exist; no output → empty output message.
- **Quit**: stops all runners (existing), keeps `shouldBeRunning`.

## Accessibility
- `StatusDot` is `accessibilityHidden`; every row/header combines into one
  element: "dionysus-xcode, running build-and-notarize, blackpaw-studio";
  "ghast-release, error, exited with code 1 at 10:05 AM".
- Output rows: "06:58:02, Connected to GitHub"; glyph meaning is spoken
  ("job failed"). The live line is announced politely when a job starts or
  ends (`AccessibilityNotification.Announcement`), not per line.
- All icon-only buttons have labels and `.help`. Stat stacks read "Uptime, 3
  hours 14 minutes".
- Keyboard-only: every action is in the menu bar with the shortcuts above;
  sidebar, segmented control, output, find bar and forms are reachable with
  Tab under Full Keyboard Access; sheets have default/cancel actions; context
  menu actions duplicate menu commands.
- Colour is never the only signal (words everywhere); Increase Contrast and
  Reduce Transparency are respected by the system materials; Reduce Motion
  disables the cursor blink and the progress spinners fall back to static
  text where SwiftUI allows.

## Testing
Test-first (Swift Testing) for logic; no network, no sleeps (injected clock,
transport, sleeper, file trasher).
- `OutputParserTests`: each line kind; ISO and legacy prefixes; runner prefix
  stripping; blank lines; CRLF; partial last line; incremental offsets and
  truncation; version; current job across start/end/listening; Jobs Today
  across midnight with a fixed calendar/time zone; the kit's dionysus-xcode
  log yields 5 jobs today, version 2.329.0, current job build-and-notarize.
- `RunnerDisplayStatusTests`: process state × activity → status, title,
  subtitle, VoiceOver string; remote online/busy/offline.
- `RunnerCatalogTests`: same name + scope merges; different scope stays
  separate; case-insensitive match; failed scope keeps last good with stale
  flag; ordering; empty sections.
- `AppSettingsTests`: defaults, persistence; `LocalRunner` legacy decode
  (`status: running` → `shouldBeRunning`).
- `RestartAtLaunchTests`, `NotificationPolicyTests` (unexpected vs requested
  stop, exit 0/2 restarts, job failure opt-in, permission asked once),
  `RemoveRunnerTests` (happy path, GitHub failure → local-only path),
  `NewRunnerNameTests`, `DurationFormatTests`, `RefreshSchedulerTests`
  (cadence, backoff, rate-limit reset).
- Wrapper integration test: fake `run.sh` exiting 1 → process exit 1, marker
  written, status `.error`; exiting 0 once then 1 → one restart then error.
- Snapshot tests (swift-snapshot-testing) per screen and state from the design
  fixture, light and dark, at mockup sizes: main (running, idle, stopped,
  starting, error, remote, empty), configuration, welcome, device code, new
  runner configure/progress, settings general/account, account not-granted.
  These lock layout; they don't prove glass (see Risks).
- Old dashboard/repo/org/banner/stat-card snapshot tests are deleted with
  their views.

## Fidelity protocol
1. **Design fixture launch mode** (DEBUG builds only, compiled out of
   Release): `Ghast -GhastDesignFixture <screen> [-GhastAppearance dark]`.
   It swaps in `FixtureDependencies`: no network, frozen clock Mon Nov 16
   2026 10:12 AM local, host "Dionysus", account Evan Coleman (EC), org
   blackpaw-studio, repo blackpaw-studio/ghast, the kit's five runners with
   exact statuses, labels, uptimes, versions, folders and the dionysus-xcode
   log; plausible fixture logs for dionysus-arm64 (idle) and ghast-release
   (error at 10:05, registration-deleted lines) until ErrorRunner.png pins
   them. Device code "WDJB-MJHT"; setup progress frozen at "Start runner".
   Screens: `main`, `configuration`, `remote`, `error`, `first-run`,
   `welcome`, `device-code`, `new-runner`, `new-runner-progress`,
   `settings-general`, `settings-account`, `menu-bar`.
2. **Capture**: `scripts/fidelity/capture.sh <screen>` launches the fixture,
   sizes the window to the mockup's window size (main 1240 × 780, welcome
   560 × 520, settings 620 wide), captures it at 2x with `screencapture -l
   <windowID> -o`, and writes `build/fidelity/<screen>[-dark].png`.
3. **Compare**: `scripts/fidelity/compare.sh <screen>` crops the mockup to the
   window rect (×2) and writes a side-by-side and a 50% overlay. Review is
   visual at native pixels; pixel diffs are a guide only (desktop backdrop
   and glass sampling differ).
4. **Deviation log**: `docs/design/focus-redesign/fidelity.md`, one table per
   screen: deviation · fixed (commit) or native-control difference (reason).
   A screen is done when every deviation is fixed or listed. Known native
   differences up front: menu submenu side, notification banner chrome,
   toolbar glass group spacing, sidebar metrics, avatar images (fixture uses a
   bundled stand-in; New Runner and Settings mockups disagree on it).
5. Snapshot tests from the same fixture lock the result.
6. Each phase captures and logs the screens it touches; the final cleanup
   phase recaptures everything in light and dark.

## Phased delivery (one PR each, in order)
1. **Foundation**: deployment target 26.0; prove window capture of Liquid
   Glass on the build host (gate for everything after); parser, activity,
   process state, exit-code propagation, ISO timestamps and markers;
   `LocalRunner` fields + migration; `RunnerCatalog`; `AppSettings`; injected
   clock/host/trasher; `FocusMetrics`/`FocusType`; fixture data layer and
   launch-argument skeleton; capture/compare scripts. No visible UI change
   beyond the OS bump.
2. **Main window**: `Window` scene, sidebar, status header, Output (follow,
   find, copy, clear), Configuration, remote, error, stopped, starting and
   empty states, toolbar, context menus, menu commands, remote refresh
   scheduler. Old navigation becomes unreachable (deleted in phase 5).
3. **Flows**: Welcome + device code windows, New Runner configure/progress
   (label token field, runner groups, advanced), Remove Runner, Remove from
   GitHub, Reconfigure.
4. **Settings and background**: Settings window (General, Account,
   permissions grant), open at login, restart at launch, menu bar extra,
   notifications, Sparkle toggle and Check Now, appcast
   `sparkle:minimumSystemVersion` 26.0.
5. **Cleanup**: delete Dashboard, repo/org pages, old sidebar, Settings page,
   `ScopeUpgradeBanner`, `RunnerStats`, stat cards and their tests/snapshots;
   update CLAUDE.md; full suite; full light/dark recapture; final fidelity log.

## Risks
1. **Window capture of Liquid Glass on the build host is unproven.**
   `screencapture -l` needs a logged-in GUI session, Screen Recording
   permission for the capturing process, and a HiDPI display (real or virtual)
   for 2x. Glass may capture flat or without backdrop sampling. Phase 1 must
   produce a 2x capture of a glass toolbar + sidebar window that matches what
   is on screen before any UI work starts; if it can't, stop and decide a
   fallback (capture on another Mac) with the owner.
2. Snapshot tests render through `NSHostingView` off-screen, where glass and
   vibrancy may not render; they guard layout only. Glass fidelity rests on
   window captures.
3. Native toolbar, sidebar and Settings tab metrics may not be adjustable to
   the mockup's exact pixels; those become logged native differences, not
   custom chrome.
4. The build host runs macOS 27 while the target is 26; glass rendering can
   differ between them. Spot-check one capture on a 26 machine before release.
5. Raising the minimum to 26 strands macOS 15 users on 1.1.0; the appcast's
   minimum system version must be set or Sparkle offers them an update that
   won't launch.
6. Runner output text changes across runner versions; unknown lines degrade
   to plain and status falls back to process state, never a crash.
7. Changing the wrapper script affects runners already running at upgrade;
   they keep the old wrapper until restarted (legacy parsing covers them).
8. Removal is partly irreversible (GitHub unregistration); folder goes to the
   Trash, never deleted.
9. Many scopes × 60 s polling can approach rate limits; scheduler honours
   reset headers.

## Open questions (owner's call)
1. ~~Errored runner's word in the menu bar~~ Resolved: the menu shows
   "Exited" with the red dot (MenuBar.png re-rendered), matching the sidebar.
Approved by Evan 2026-11-16 with the recommended defaults for 2 and 3:
regular Dock app; ship as 2.0, macOS 15 users stay on 1.1.0.

2. **Dock icon.** Keep Ghast a regular Dock app (current, recommended), or
   switch to menu-bar-only (accessory) when the menu bar extra is on and no
   window is open?
3. **Release numbering.** Ship the redesign as 2.0 with minimum macOS 26 and
   leave macOS 15 users on 1.1.0 (recommended), or cut a final 1.x first?
