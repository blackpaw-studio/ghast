#!/bin/bash

# Script to record/update snapshot tests for Ghast
# Usage: ./Scripts/record-snapshots.sh [test-filter]
# Example: ./Scripts/record-snapshots.sh SimpleSnapshotTest

echo "🎬 Recording snapshot tests..."

if [ -z "$1" ]; then
    echo "Recording ALL snapshot tests"
    xcodebuild test \
        -project Ghast.xcodeproj \
        -scheme Ghast-RecordSnapshots \
        -destination 'platform=macOS'
else
    echo "Recording snapshots for: $1"
    xcodebuild test \
        -project Ghast.xcodeproj \
        -scheme Ghast-RecordSnapshots \
        -destination 'platform=macOS' \
        -only-testing:"GhastTests/$1"
fi

echo "✅ Snapshot recording complete!"
echo "📸 Check git status to see updated snapshots"