#!/usr/bin/env bash
# Capture gate (spec risk #1): proves a 2x window capture of Liquid Glass works on this host.
#
#   Scripts/fidelity/probe.sh
#
# 1. Starts the 1440x900 pt HiDPI virtual display.
# 2. Launches the glass probe there: a NavigationSplitView with glass toolbar groups, in front
#    of a window painted with high-contrast stripes.
# 3. Captures it with `screencapture -l <id> -o`, and the same rect with `screencapture -R`.
# 4. Asserts (a) the window capture is exactly 2x the window size, (b) the sidebar shows
#    blurred stripes (variance above a flat fill, below the sharp stripes), so glass sampled
#    its backdrop, (c) the -l and -R captures agree.
#
# Exits 0 only if every assertion holds. Output: build/fidelity/probe-*.png.
# Needs Screen Recording granted to the process that runs this script.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need magick
need screencapture
mkdir -p "$OUT_DIR"

# Sidebar region inside the probe window, in points from the window's top-left (below the
# toolbar, clear of the rounded corners).
SIDEBAR_X=16 SIDEBAR_Y=120 SIDEBAR_W=200 SIDEBAR_H=300
# -l vs -R agreement: normalised RMSE must stay under this (corners and shadow differ a little).
AGREE_MAX="0.03"
# Blur window: stddev of the sidebar crop, as a fraction of the sharp backdrop's.
BLUR_MIN_ABS="0.01"
BLUR_MAX_RATIO="0.6"

start_virtual_display

build_tool glass-probe -parse-as-library "$FIDELITY_DIR/probe/GlassProbe.swift"
PROBE_LOG="$OUT_DIR/probe.log"
: > "$PROBE_LOG"
"$BIN_DIR/glass-probe" > "$PROBE_LOG" 2>&1 &
track_pid $!

READY="$(wait_for_line "$PROBE_LOG" '^probe-(ready|error)' 30)" || die "probe never became ready; see $PROBE_LOG"
case "$READY" in probe-error*) die "$READY" ;; esac
WINDOW_ID="$(sed -E 's/.* window=([0-9]+).*/\1/' <<<"$READY")"
BACKDROP_ID="$(sed -E 's/.* backdrop=([0-9]+).*/\1/' <<<"$READY")"
RECT="$(sed -E 's/.* rect=([0-9,-]+).*/\1/' <<<"$READY")"
IFS=, read -r RX RY RW RH <<<"$RECT"

WIN_PNG="$OUT_DIR/probe-window.png"
REGION_PNG="$OUT_DIR/probe-region.png"
BACKDROP_PNG="$OUT_DIR/probe-backdrop.png"
screencapture -x -l "$WINDOW_ID" -o "$WIN_PNG"
screencapture -x -R "$RX,$RY,$RW,$RH" "$REGION_PNG"
screencapture -x -l "$BACKDROP_ID" -o "$BACKDROP_PNG"

FAILED=0
check() { # check <label> <ok: 0|1> <detail>
    if [ "$2" -eq 1 ]; then echo "PASS  $1: $3"; else echo "FAIL  $1: $3"; FAILED=1; fi
}

# (a) exactly 2x
read -r WIDTH HEIGHT < <(magick identify -format '%w %h\n' "$WIN_PNG")
EXPECT_W=$((RW * 2)) EXPECT_H=$((RH * 2))
if [ "$WIDTH" -eq "$EXPECT_W" ] && [ "$HEIGHT" -eq "$EXPECT_H" ]; then ok=1; else ok=0; fi
check "window capture is 2x" "$ok" "${WIDTH}x${HEIGHT}, expected ${EXPECT_W}x${EXPECT_H}"

# (b) glass sampled its backdrop: stddev between "flat" and the sharp stripes' own.
sidebar_crop="$((SIDEBAR_W * 2))x$((SIDEBAR_H * 2))+$((SIDEBAR_X * 2))+$((SIDEBAR_Y * 2))"
backdrop_crop="$((SIDEBAR_W * 2))x$((SIDEBAR_H * 2))+$(((RX + SIDEBAR_X) * 2))+$(((RY + SIDEBAR_Y) * 2))"
stddev() { magick "$1" -crop "$2" +repage -colorspace Gray -format '%[fx:standard_deviation]' info:; }
SIDEBAR_SD="$(stddev "$WIN_PNG" "$sidebar_crop")"
SOURCE_SD="$(stddev "$BACKDROP_PNG" "$backdrop_crop")"
ok="$(awk -v s="$SIDEBAR_SD" -v src="$SOURCE_SD" -v lo="$BLUR_MIN_ABS" -v r="$BLUR_MAX_RATIO" 'BEGIN { print (s > lo && s < src * r) ? 1 : 0 }')"
check "sidebar glass blurs the stripes" "$ok" "sidebar stddev $SIDEBAR_SD, sharp backdrop $SOURCE_SD (need > $BLUR_MIN_ABS and < $BLUR_MAX_RATIO x source)"

# (c) -l and -R agree, ignoring the rounded corners
SHAVE=40
magick "$WIN_PNG" -shave "${SHAVE}x${SHAVE}" "$OUT_DIR/probe-window-inner.png"
magick "$REGION_PNG" -shave "${SHAVE}x${SHAVE}" "$OUT_DIR/probe-region-inner.png"
RMSE="$(magick compare -metric RMSE "$OUT_DIR/probe-window-inner.png" "$OUT_DIR/probe-region-inner.png" null: 2>&1 \
    | sed -E 's/.*\(([0-9.e+-]+)\).*/\1/' || true)"
ok="$(awk -v v="${RMSE:-1}" -v max="$AGREE_MAX" 'BEGIN { print (v + 0 < max) ? 1 : 0 }')"
check "-l and -R captures agree" "$ok" "normalised RMSE ${RMSE:-unknown}, need < $AGREE_MAX"

echo "probe images: $WIN_PNG $REGION_PNG $BACKDROP_PNG"
exit "$FAILED"
