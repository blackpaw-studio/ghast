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

1. **Update the recording flag:**
   In `SnapshotTests/SnapshotTestHelpers.swift`, change:
   ```swift
   static var isRecordingSnapshots = true  // Change to true
   ```

2. **Run the snapshot tests:**
   ```bash
   xcodebuild test -project Ghast.xcodeproj -scheme Ghast -only-testing:GhastTests/ContentViewSnapshotTests
   xcodebuild test -project Ghast.xcodeproj -scheme Ghast -only-testing:GhastTests/NewRunnerFlowSnapshotTests
   xcodebuild test -project Ghast.xcodeproj -scheme Ghast -only-testing:GhastTests/LocalRunnersViewSnapshotTests
   xcodebuild test -project Ghast.xcodeproj -scheme Ghast -only-testing:GhastTests/AddRunnerViewSnapshotTests
   ```

3. **Reset the recording flag:**
   ```swift
   static var isRecordingSnapshots = false  // Change back to false
   ```

4. **Commit the new reference images:**
   ```bash
   git add GhastTests/__Snapshots__/
   git commit -m "📸 Update UI snapshot references"
   ```

## What Gets Tested

- **ContentView/MainAppView**: Main app layout and sidebar width
- **NewRunnerFlowView**: Repository selection dialog at different sizes
- **LocalRunnersView**: Runner list with sidebar layout
- **AddRunnerView**: Runner configuration sheets

## Snapshot Location

Reference snapshots are stored in `GhastTests/__Snapshots__/` and organized by test file name.

## Testing Split View Changes

The snapshot tests specifically verify the split view width changes:

- Main sidebar: 280-320-400px (was 250-280-350px)
- Local runners sidebar: 300-350-450px (was 250-300-400px)
- New runner dialog: 800-900-1200px (was 700-800-1000px)
- Add runner sheet: 750-850-1100px (was 600-700-900px)

When you run the tests, they'll capture the actual rendered views at these sizes and compare them to the reference snapshots.