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

## main

| Deviation | Status |
|---|---|
| Toolbar glass group spacing | native: system toolbar layout |
| Sidebar metrics | native: floating sidebar sets its own insets and selection shape |

## configuration

| Deviation | Status |
|---|---|
| Toolbar glass group spacing | native: system toolbar layout |
| Sidebar metrics | native: floating sidebar sets its own insets and selection shape |

## remote

| Deviation | Status |
|---|---|
| Toolbar glass group spacing | native: system toolbar layout |
| Sidebar metrics | native: floating sidebar sets its own insets and selection shape |

## error

| Deviation | Status |
|---|---|
| Toolbar glass group spacing | native: system toolbar layout |
| Sidebar metrics | native: floating sidebar sets its own insets and selection shape |

## first-run

| Deviation | Status |
|---|---|
| Toolbar glass group spacing | native: system toolbar layout |
| Sidebar metrics | native: floating sidebar sets its own insets and selection shape |

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
