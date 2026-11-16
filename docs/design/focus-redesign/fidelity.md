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
| "Remove Runner…" renders dimmed (disabled) until the PR 3 flows | open: enabled in PR 3 |
| "Restart the runner to apply changes." footer shows only after an edit while running; the PNG shows a running runner without it | fixed: PNG wins |

## remote

| Deviation | Status |
|---|---|
| "Remove from GitHub…" in the ellipsis menu is disabled until PR 3 | open: enabled in PR 3 |

## error

| Deviation | Status |
|---|---|
| "Reconfigure…" renders dimmed (disabled) until the PR 3 flows | open: enabled in PR 3 |
| "Runner listener exited with error code 1" is red | fixed: parser rule (2.9) |

## first-run

| Deviation | Status |
|---|---|
| Empty-state glyph is the system `laptopcomputer` with a `plus` overlay; no single symbol matches the kit | native: SF Symbols |
| Body text uses hand line breaks to reproduce the PNG's balanced three-line wrap | fixed |

## welcome

| Deviation | Status |
|---|---|
| (none seeded) | open |

## device-code

| Deviation | Status |
|---|---|
| (none seeded) | open |

## new-runner

| Deviation | Status |
|---|---|
| Sheet position: the system attaches the sheet to the window, the mockup floats two sheets side by side | native: sheets are window-attached |
| Avatar image | native: fixture stand-in |

## new-runner-progress

| Deviation | Status |
|---|---|
| Sheet position: the system attaches the sheet to the window | native: sheets are window-attached |

## settings-general

| Deviation | Status |
|---|---|
| Toolbar tab metrics | native: system Settings tab toolbar |

## settings-account

| Deviation | Status |
|---|---|
| Toolbar tab metrics | native: system Settings tab toolbar |
| Avatar image | native: fixture stand-in |

## menu-bar

| Deviation | Status |
|---|---|
| Submenu opens on the side the system chooses | native: system menu placement |
| Notification banner chrome | native: drawn by Notification Center |
