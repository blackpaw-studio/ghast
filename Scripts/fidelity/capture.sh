#!/usr/bin/env bash
# Captures one design-fixture screen at 2x into build/fidelity/<screen>[-dark].png.
#
#   Scripts/fidelity/capture.sh <screen> [--dark] [--no-build]
#
# Builds Debug into build/DerivedData, starts the HiDPI virtual display, launches the fixture,
# waits (30 s cap) for its `fixture-ready window=<n> rect=<x>,<y>,<w>,<h>` line, then captures
# the window with `peekaboo see --window-id <n> --retina`. The menu-bar screen has no window of
# its own, so it captures the whole virtual display as a region instead.
#
# Captures go through Peekaboo, whose Bridge holds Screen Recording; the script fails if
# `peekaboo permissions` doesn't report it granted.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NO_BUILD=0
ARGS=()
for arg in "$@"; do
    if [ "$arg" = "--no-build" ]; then NO_BUILD=1; else ARGS+=("$arg"); fi
done
parse_screen_args ${ARGS[@]+"${ARGS[@]}"}

need xcodebuild
mkdir -p "$OUT_DIR"
require_screen_recording

if [ "$NO_BUILD" -eq 0 ]; then
    (cd "$REPO_ROOT" && xcodebuild build -project Ghast.xcodeproj -scheme Ghast -configuration Debug \
        -destination platform=macOS -derivedDataPath "$DERIVED_DATA" -quiet) || die "build failed"
fi
[ -x "$APP_BINARY" ] || die "no Debug build at $APP_BINARY"

start_virtual_display

APP_LOG="$OUT_DIR/app-$SCREEN$APPEARANCE.log"
: > "$APP_LOG"
APP_ARGS=(-GhastDesignFixture "$SCREEN" -ApplePersistenceIgnoreState YES)
[ -n "$APPEARANCE" ] && APP_ARGS+=(-GhastAppearance dark)
"$APP_BINARY" "${APP_ARGS[@]}" > "$APP_LOG" 2>&1 &
APP_PID=$!
track_pid "$APP_PID"

READY="$(wait_for_line "$APP_LOG" '^fixture-(ready|error)' 30)" || die "fixture never became ready within 30 s; see $APP_LOG"
case "$READY" in fixture-error*) die "$READY" ;; esac
WINDOW_ID="$(sed -E 's/.* window=([0-9]+).*/\1/' <<<"$READY")"
RECT="$(sed -E 's/.* rect=([0-9,]+).*/\1/' <<<"$READY")"

OUT_PNG="$OUT_DIR/$SCREEN$APPEARANCE.png"
# The mockups show active windows, so never capture an inactive one.
[ "$WINDOW_ID" = "0" ] || require_active_window "$APP_PID" "$WINDOW_ID"
if [ "$WINDOW_ID" = "0" ]; then
    # Region capture of the whole virtual display, x,y,w,h in global points.
    peek_region "$VD_ORIGIN,1440,900" "$OUT_PNG"
else
    peek_window "$WINDOW_ID" "$OUT_PNG"
fi
# The rect is recorded relative to the virtual display's top-left, which is where the 1440x900
# mockups are measured from (the window itself reports global coordinates).
if [ "$WINDOW_ID" != "0" ]; then
    IFS=, read -r RX RY RW RH <<<"$RECT"
    IFS=, read -r VDX VDY <<<"$VD_ORIGIN"
    RECT="$((RX - VDX)),$((RY - VDY)),$RW,$RH"
fi
echo "$RECT" > "$OUT_DIR/$SCREEN$APPEARANCE.rect"
echo "$OUT_PNG"
