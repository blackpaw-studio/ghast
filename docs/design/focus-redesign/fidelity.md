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
