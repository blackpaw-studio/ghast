# Ghast Scripts

This directory contains utility scripts for the Ghast project.

## record-snapshots.sh

Records/updates snapshot tests using the `Ghast-RecordSnapshots` scheme.

### Usage

Record all snapshot tests:
```bash
./Scripts/record-snapshots.sh
```

Record snapshots for a specific test class:
```bash
./Scripts/record-snapshots.sh FocusMainSnapshotTests
```

### How it works

The script uses the `Ghast-RecordSnapshots` Xcode scheme which sets the `SNAPSHOT_RECORD_MODE=true` environment variable. This tells the snapshot testing framework to update reference images instead of comparing them.

After recording, check `git status` to see which snapshot images were updated, then commit the changes if they look correct.