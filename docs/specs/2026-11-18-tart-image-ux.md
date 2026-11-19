# Tart image UX: pull progress and Xcode versions — Spec

Status: approved by Evan 2026-11-18. Builds on `2026-11-18-tart-vm-runners.md`.

## 1. Determinate pull progress

- `tart pull` (non-TTY) prints `pulling <ref>...`, `pulling manifest...`,
  `pulling disk (27.0 GB compressed)...`, then one `N%` line per percent.
- `TartCLI.pull` streams output line by line and reports progress
  (fraction 0–1 from `N%` lines; compressed size string from the
  `pulling disk (…)` line). Unrecognised lines go to the runner log unchanged.
- The pulling phase carries optional progress and size. Before the first `N%`
  line it is indeterminate (spinner).
- Sidebar subtitle: "Pulling image · 42%". Detail header: determinate progress
  bar instead of the spinner with "Pulling <image label> — 42% of 27.0 GB".
  Menu bar shows the percentage.
- The runner log keeps the `pulling disk (…)` line and completion, not the
  ~100 percentage lines.
- Out of scope: speed/ETA, runner-tarball download progress.

## 2. Xcode version picker

- New Runner image picker becomes: **macOS** (Tahoe / Sequoia) and **Xcode**
  ("None (base image)" or a version), plus the existing "Custom image…".
- Xcode versions are fetched live from ghcr.io when the sheet opens:
  anonymous token `GET https://ghcr.io/token?scope=repository:cirruslabs/<repo>:pull`,
  then `GET https://ghcr.io/v2/cirruslabs/<repo>/tags/list?n=1000`, where repo is
  `macos-<tahoe|sequoia>-xcode`. Release tags only (numeric `X`, `X.Y`,
  `X.Y.Z`; hide `-beta`, `-rc`, `latest`, digests), sorted newest first by
  numeric version; default the newest.
- On fetch failure: a short built-in fallback list per macOS version and a
  one-line note that versions couldn't be loaded.
- Saved image is the exact tag, e.g. `ghcr.io/cirruslabs/macos-tahoe-xcode:27.2`.
  Base images keep `:latest`.
- Image label (pure function of the ref) shown in the sidebar subtitle and
  detail header: "macOS Tahoe · Xcode 27.2", "macOS Tahoe" for base,
  "Xcode (latest)" for an existing `-xcode:latest` ref, the raw ref for custom
  images. The Configuration tab keeps the full ref and offers the same
  macOS/Xcode picker.
- Existing VM runners on `-xcode:latest` keep working unchanged.

## Testing

- Unit: pull-output parser (percent lines, size line, junk lines, partial
  lines); tag filter/sort; image label; registry client via fake transport
  (token + tags, failure → fallback).
- Snapshots: new-runner sheet with Xcode picker (loaded and fallback);
  detail in pulling state at 42% with size.
