# Snapshot Testing Setup

This project uses [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing) to verify UI layouts and prevent regressions.

## Running Snapshot Tests

1. **Build the project first:**
   ```bash
   xcodebuild -project Ghast.xcodeproj -scheme Ghast build
   ```

2. **Run the tests:**
   ```bash
   xcodebuild test -project Ghast.xcodeproj -scheme Ghast
   ```

## Recording New Snapshots

When you need to record new reference snapshots (e.g., after UI changes):

1. **Record:**
   ```bash
   TEST_RUNNER_SNAPSHOT_RECORD_MODE=true xcodebuild test -project Ghast.xcodeproj -scheme Ghast -only-testing:GhastTests/FocusMainSnapshots
   ```
   Suites: `FocusMainSnapshots`, `FocusFlowSnapshots`, `FocusSettingsSnapshots`.

2. **Re-run without the variable** to confirm green, then commit `GhastTests/__Snapshots__/`.

## What Gets Tested

- **FocusMainSnapshots**: the main window's detail column in each runner state, light and dark
- **FocusFlowSnapshots**: welcome, device code, New Runner and its progress
- **FocusSettingsSnapshots**: Settings General and Account

## Snapshot Location

Reference snapshots are stored in `GhastTests/__Snapshots__/` and organized by suite name.
