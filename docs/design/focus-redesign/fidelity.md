# Focus redesign: fidelity log

One table per screen. A screen is done when every deviation from its mockup is either **fixed** (with the commit) or listed as a **native-control difference** with its reason.

Capture and compare (see `Scripts/fidelity/`):

```
Scripts/fidelity/capture.sh <screen> [--dark]   # build/fidelity/<screen>[-dark].png
Scripts/fidelity/compare.sh <screen> [--dark]   # -side.png and -overlay.png next to it
```

Review is visual at native pixels. Pixel diffs are only a guide, because the desktop backdrop and glass sampling differ. Status: `open`, `fixed (<commit>)`, or `native: <reason>`.

Known native differences from the spec (seeded; each repeats on every screen it touches):

- Toolbar glass group spacing: the system lays out `ToolbarSpacer` and group capsules.
- Sidebar metrics: the native floating sidebar sets its own insets, row selection shape and section header height.
- Avatar images: the fixture bundles a stand-in, and the New Runner and Settings mockups disagree on it.
- Menu submenu side: the system chooses it (the mockup shows left).
- Notification banner chrome: drawn by Notification Center, not by Ghast.
- Capture focus state: a capture can catch the window active or inactive (grey traffic lights and controls). It varies run to run with no code change (PR 5 recapture: welcome, error and configuration-dark each differed from the PR 4 captures only in active state). Recapture before judging a control's colour.

PR 5 recapture: all 12 screens, light and dark, re-run after the old UI was deleted. Pixel-identical (10% fuzz) to the PR 4 captures for 17 of 24, and the other 7 differ only in window active state, a few menu bar clock pixels, or sub-0.01% anti-aliasing. No regressions; no open rows.

## Main window chrome

Measured on the build host (macOS 27) with `Scripts/fidelity/probe.sh`, on a standard `NavigationSplitView` with a `List(.sidebar)`. No custom chrome is drawn, so these stay as native differences from the mockups. macOS 26 users may see the inset floating sidebar style; the host does not, so the capture cannot confirm it.

| Deviation | Status |
|---|---|
| Sidebar is full-bleed (flush to the window edge, full height), not the mockups' inset rounded floating panel. Variants tried, none gave the inset: (a) default `WindowGroup` and toolbar style, (b) `.windowToolbarStyle(.unified)` on the scene, (c) `.navigationSplitViewStyle(.balanced)`, (d) `.containerBackground(.regularMaterial, for: .window)`. `containerBackground(for: .navigation)` is unavailable on macOS. | native: macOS 27 host renders the sidebar full-bleed |
| Sidebar selection is the system accent colour (solid blue on an active window), not the mockups' neutral grey row | native: selection is drawn by `List`, which follows the accent colour |
| Toolbar glass capsules blur the content scrolling under them to a near-flat tint (stddev 0.004 against 0.248 for the sharp content) | native: system glass |

## Main window content (main, configuration, remote, error, first-run)

PR 2 captures, light and dark. The content layer is placed at the kit's window coordinates (content top 64, detail inset 32, sidebar column 264). Deviations shared by all five screens:

| Deviation | Status |
|---|---|
| Native toolbar is about 52 pt tall, not 64: the title sits at x 268–284, y 19 (kit 296, 25) and the traffic lights sit higher | native: system toolbar; content is pinned to the kit's y 64 independently |
| Toolbar glyphs (`stop.fill`, `arrow.clockwise`, `plus`, `ellipsis`) and capsules are the system toolbar size, a little larger than the kit's | native: system toolbar buttons |
| Toolbar glass group spacing | native: `ToolbarSpacer(.fixed)` between groups, system layout |
| Sidebar rows follow native list insets, about 11 pt left of the kit's; section headers use the native sidebar style | native: `List(.sidebar)` |
| Sidebar status dots look darker through the sidebar's vibrancy | native: sidebar material |
| Dark window background is the system's (41, 39, 38), not the kit's `--win` #1e1e20; groups, fields and the script editor keep the kit's relative contrast | native: kit says content is plain window background |
| `borderedProminent` buttons use the system accent blue | native: system accent |
| Toolbar has no bar background (`toolbarBackgroundVisibility(.hidden)`), so screens without a scroll view no longer show a title-bar band in dark | fixed (2.11) |

## main

| Deviation | Status |
|---|---|
| Output glyph column is 12 pt and the live line 23 pt (spec: 16 and 24) | fixed: measured from Main.png, PNG wins |
| Header status dot is 8 pt | fixed: measured in PR 1 |
| Output copy icon is `square.on.square` (spec said `doc.on.doc`) | fixed: PNG wins |
| `trash` symbol has inner lines the kit's icon lacks | native: SF Symbol |
| Monospaced output uses −0.2 tracking to match the kit's 7.22 pt advance (system mono is 7.42) | fixed |

## configuration

| Deviation | Status |
|---|---|
| Job-script switches are the system small switch, not the kit's 38 × 22 | native: `Toggle(.switch)` `.controlSize(.small)` |
| Environment variable rows are centred; the mockup's text sits about 1.75 pt off-centre | fixed: capture is centred, mockup drift ignored |
| "Remove Runner…" renders dimmed (disabled) until the PR 3 flows | fixed (PR 3 · 3.7) |
| "Restart the runner to apply changes." footer shows only after an edit while running; the PNG shows a running runner without it | fixed: PNG wins |

## remote

| Deviation | Status |
|---|---|
| "Remove from GitHub…" in the ellipsis menu is disabled until PR 3 | fixed (PR 3 · 3.7) |

## error

| Deviation | Status |
|---|---|
| "Reconfigure…" renders dimmed (disabled) until the PR 3 flows | fixed (PR 3 · 3.7) |
| "Runner listener exited with error code 1" is red | fixed: parser rule (2.9) |

## first-run

| Deviation | Status |
|---|---|
| Empty-state glyph is the system `laptopcomputer` with a `plus` overlay; no single symbol matches the kit | native: SF Symbols |
| Body text uses hand line breaks to reproduce the PNG's balanced three-line wrap | fixed |

## welcome

| Deviation | Status |
|---|---|
| App icon is Ghast's real artwork; the kit draws a stand-in ghost squircle | native: shipped app icon |
| Traffic lights sit where the hidden title bar puts them, a few points higher and left of the kit | native: window chrome |
| Zoom button is greyed because the window is fixed-size (`.contentSize`) | native: window chrome |
| Feature glyphs are SF `laptopcomputer`, `terminal`, `rectangle.inset.bottomright.filled`; the laptop screen is tinted and the third is the nearest match to the kit's | native: SF Symbols |
| Window background is the system window color, a touch warmer than the kit in dark mode | native: window material |
| Sign In button height and footnote position | fixed |

## device-code

| Deviation | Status |
|---|---|
| Key glyph is SF `key` turned 45° to the kit's angle; its bit is a notch rather than the kit's teeth | native: SF Symbols |
| Traffic lights and greyed zoom button, as on welcome | native: window chrome |
| Button heights (36 pt) and gap above the buttons | fixed |

## new-runner

| Deviation | Status |
|---|---|
| Sheet position: the system attaches the sheet to the window and centres it vertically; the mockup floats two sheets side by side near the top | native: sheets are window-attached |
| The window under the sheet draws inactive and without the kit's scrim | native: sheet presentation |
| Avatar image: a monogram drawn as an `NSImage` (menu items can't host views); real avatars load from GitHub | native: fixture stand-in |
| "Add to" is the system menu popup: filled bezel, sized to its widest item, icon tight to the title | native: `Picker(.menu)` |
| The Name field selects the suggested name when it takes focus | native: text field focus |
| Labels field is a SwiftUI token row in a text-field-coloured box, not `NSTokenField`, so the default labels can be fixed | native: no system token field with fixed tokens |
| "Add Label" text column narrowed to 64 pt because SF tokens run 7 pt wider than the kit's | fixed |

## new-runner-progress

| Deviation | Status |
|---|---|
| The window under the sheet draws inactive and without the kit's scrim | native: sheet presentation |
| Disabled Done is the system's disabled prominent button, close to the kit's 45% accent | native: button state |
| Sheet position: the system attaches the sheet to the window | native: sheets are window-attached |

## confirmation alerts (no mockup)

| Deviation | Status |
|---|---|
| Remove Runner, Remove from This Mac Only, Reconfigure and Remove from GitHub use the system alert with the spec's wording; the kit draws none of them (captures: `build/fidelity/alert-*.png`) | native: system alerts |

## settings-general

Captures: `build/fidelity/settings-general{,-dark}-side.png`. Content is locked by `FocusSettingsSnapshotTests`.

| Deviation | Status |
|---|---|
| Tab toolbar is about 24 pt taller than the kit (88 against 64 pt), so the content sits 24 pt lower; the traffic lights centre on it and minimize/zoom are disabled | native: system `Settings` scene `TabView` toolbar |
| Selected tab is an accent-tinted label in a bordered capsule, not the kit's grey pill | native: system Settings tab selection |
| Switches are the system small switch, 44 × 20 pt (kit 38 × 22) | native: `Toggle(.switch)` at `.controlSize(.small)` |
| Group fill is `quaternarySystemFill` (248 against the kit's 243 in light), as on Configuration | native: system fill colour |
| Pane title and the bar under the tabs | fixed (2852aa5): `.toolbar(removing: .title)`, hidden toolbar background |
| Switch size, folder row height (40 pt), help spacing, curly apostrophes | fixed (2852aa5) |

## settings-account

Captures: `build/fidelity/settings-account{,-dark}-side.png`. The not-granted state has no mockup and is locked by the `account-not-granted` snapshot only.

| Deviation | Status |
|---|---|
| Tab toolbar height and selected-tab style, as on settings-general | native: system `Settings` scene `TabView` toolbar |
| Initials and tab glyph use the system blue accent, not the kit's `--accent-ink` | native: system accent colour |
| Organization avatar is a monogram, not the kit's paw image | native: fixture stand-in (no network in the fixture) |
| Group fill, as on settings-general | native: system fill colour |
| Dark window background is the system's, slightly lighter than the kit | native: system window background |

## menu-bar

Captures: `build/fidelity/menu-bar{,-dark}-side.png` (region capture of the whole screen; the fixture pops the menu at the kit's coordinates and hovers dionysus-xcode).

| Deviation | Status |
|---|---|
| Menu is placed at the kit's coordinates on the capture display, not under Ghast's status item; the system positions the status item among the host's other items | native: status item placement belongs to the system |
| Menu bar shows the host's own items and app menus | native: capture host |
| Ghost status item is not drawn pressed | native: the fixture pops the menu without clicking the item |
| Submenu opens to the right, the kit shows left | native: system menu placement |
| Section header ("This Mac") is lighter than the kit | native: `NSMenuItem.sectionHeader` style |
| Shortcut glyph spacing (⌘, and ⌘Q) | native: system key-equivalent drawing |
| Status word is a tab-aligned secondary attributed title, not `NSMenuItem.badge` | fixed (72f6150): the PNG shows plain text, and the badge draws a pill |
| Status dots missing (macOS 27 hides menu-item images by default) | fixed (72f6150): `preferredImageVisibility = .visible` on macOS 27 |
| Crash notification banner | native: drawn by Notification Center. Not captured: posting it for real would request notification authorization for `net.evancoleman.ghast` on the build host. Its words are locked by `NotificationPolicyTests` |
