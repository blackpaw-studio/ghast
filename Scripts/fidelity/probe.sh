#!/usr/bin/env bash
# Capture gate (spec risk #1): proves an active, 2x window capture of Liquid Glass works here.
#
#   Scripts/fidelity/probe.sh
#
# 1. Starts the 1440x900 pt HiDPI virtual display.
# 2. Launches the glass probe there: a NavigationSplitView with an inset sidebar and glass
#    toolbar capsules, over a detail area of high-contrast stripes that scroll under a capsule.
# 3. Requires Peekaboo to report the probe window frontmost and key (captures must be of the
#    active state), then captures it with `peekaboo see --window-id <id> --retina`, and the
#    same rect as a region (`--mode area --region`).
# 4. Asserts (a) the window capture is exactly 2x the window's real size, (b) the traffic lights
#    render in colour (active), (c) the stripes under the capsule are blurred, not sharp and not
#    flat (glass sampled its own content), (d) the sidebar is an inset rounded panel, and (e) the
#    window and region captures agree.
#
# Exits 0 only if every assertion holds. Output: build/fidelity/probe-*.png.
# Captures go through Peekaboo (its Bridge holds Screen Recording); the script fails if
# `peekaboo permissions` doesn't report it granted.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need magick
mkdir -p "$OUT_DIR"
require_screen_recording

# Unobstructed stripes: a patch of the detail area well below the toolbar, in points from the
# window's top-left. The capsule's own frame comes from the probe.
STRIPES_X=500 STRIPES_Y=300 STRIPES_W=200 STRIPES_H=300
# The capsule interior is inset by this many points so its edge and shadow are excluded.
CAPSULE_INSET=4
# Blurred stripes: stddev strictly between a flat fill and the sharp stripes' own.
BLUR_MIN_ABS="0.001"
BLUR_MAX_RATIO="0.75"
# Active traffic lights, sampled at their centres (points from the window's top-left). The zoom
# light is grey in a fixed-size window, so close (red) and minimise (yellow) carry the check.
CLOSE_X=25 CLOSE_Y=24
MINIMIZE_X=49 MINIMIZE_Y=24
# Sidebar inset: a pixel in the panel's rounded corner shows the window background, which must
# differ from the panel fill by at least this much (0-1 luminance).
CORNER_OFFSET=11
SIDEBAR_FILL_X=100 SIDEBAR_FILL_FROM_BOTTOM=60
INSET_MIN_DELTA="0.01"
# window vs region agreement: normalised RMSE must stay under this.
AGREE_MAX="0.03"

start_virtual_display

build_tool glass-probe -parse-as-library "$FIDELITY_DIR/probe/GlassProbe.swift"
PROBE_LOG="$OUT_DIR/probe.log"
: > "$PROBE_LOG"
"$BIN_DIR/glass-probe" > "$PROBE_LOG" 2>&1 &
track_pid $!

READY="$(wait_for_line "$PROBE_LOG" '^probe-(ready|error)' 30)" || die "probe never became ready; see $PROBE_LOG"
case "$READY" in probe-error*) die "$READY" ;; esac
field() { sed -E "s/.* $1=([^ ]+).*/\1/" <<<"$READY"; }
WINDOW_ID="$(field window)"
BACKDROP_ID="$(field backdrop)"
PROBE_PID="$(field pid)"
IFS=, read -r RX RY RW RH <<<"$(field rect)"
IFS=, read -r CX CY CW CH <<<"$(field capsule)"

require_active_window "$PROBE_PID" "$WINDOW_ID"

WIN_PNG="$OUT_DIR/probe-window.png"
REGION_PNG="$OUT_DIR/probe-region.png"
peek_window "$WINDOW_ID" "$WIN_PNG"
peek_region "$RX,$RY,$RW,$RH" "$REGION_PNG"

FAILED=0
check() { # check <label> <ok: 0|1> <detail>
    if [ "$2" -eq 1 ]; then echo "PASS  $1: $3"; else echo "FAIL  $1: $3"; FAILED=1; fi
}
stddev() { magick "$1" -crop "$2" +repage -colorspace Gray -format '%[fx:standard_deviation]' info:; }

# (a) exactly 2x the window's real size
read -r WIDTH HEIGHT < <(magick identify -format '%w %h\n' "$WIN_PNG")
EXPECT_W=$((RW * 2)) EXPECT_H=$((RH * 2))
if [ "$WIDTH" -eq "$EXPECT_W" ] && [ "$HEIGHT" -eq "$EXPECT_H" ]; then ok=1; else ok=0; fi
check "window capture is 2x" "$ok" "${WIDTH}x${HEIGHT}, expected ${EXPECT_W}x${EXPECT_H}"

# (b) active window: coloured traffic lights (red close, yellow minimise)
read -r CR CG CB <<<"$(rgb_at "$WIN_PNG" $((CLOSE_X * 2)) $((CLOSE_Y * 2)))"
read -r MR MG MB <<<"$(rgb_at "$WIN_PNG" $((MINIMIZE_X * 2)) $((MINIMIZE_Y * 2)))"
if [ "$CR" -gt 180 ] && [ "$CG" -lt 130 ] && [ "$MR" -gt 200 ] && [ "$MG" -gt 150 ] && [ "$MB" -lt 100 ]; then ok=1; else ok=0; fi
check "traffic lights are in colour" "$ok" "close rgb($CR,$CG,$CB) wants red, minimise rgb($MR,$MG,$MB) wants yellow"

# (c) glass sampled and blurred its own content under the capsule
capsule_crop="$(( (CW - 2 * CAPSULE_INSET) * 2 ))x$(( (CH - 2 * CAPSULE_INSET) * 2 ))+$(( (CX + CAPSULE_INSET) * 2 ))+$(( (CY + CAPSULE_INSET) * 2 ))"
stripes_crop="$((STRIPES_W * 2))x$((STRIPES_H * 2))+$((STRIPES_X * 2))+$((STRIPES_Y * 2))"
CAPSULE_SD="$(stddev "$WIN_PNG" "$capsule_crop")"
STRIPES_SD="$(stddev "$WIN_PNG" "$stripes_crop")"
ok="$(awk -v c="$CAPSULE_SD" -v src="$STRIPES_SD" -v lo="$BLUR_MIN_ABS" -v r="$BLUR_MAX_RATIO" 'BEGIN { print (c > lo && c < src * r) ? 1 : 0 }')"
check "capsule glass blurs the stripes under it" "$ok" "capsule stddev $CAPSULE_SD (crop $capsule_crop), sharp stripes $STRIPES_SD (need > $BLUR_MIN_ABS and < $BLUR_MAX_RATIO x stripes)"
magick "$WIN_PNG" -crop "$capsule_crop" +repage "$OUT_DIR/probe-capsule.png"

# (d) the sidebar is an inset rounded panel: its corner shows the window background, not the fill
CORNER_GRAY="$(gray_at "$WIN_PNG" $((CORNER_OFFSET * 2)) $((HEIGHT - CORNER_OFFSET * 2)))"
FILL_GRAY="$(gray_at "$WIN_PNG" $((SIDEBAR_FILL_X * 2)) $((HEIGHT - SIDEBAR_FILL_FROM_BOTTOM * 2)))"
ok="$(awk -v a="$CORNER_GRAY" -v b="$FILL_GRAY" -v min="$INSET_MIN_DELTA" 'BEGIN { d = a - b; if (d < 0) d = -d; print (d >= min) ? 1 : 0 }')"
check "sidebar is an inset rounded panel" "$ok" "corner luminance $CORNER_GRAY vs panel fill $FILL_GRAY (need a difference of at least $INSET_MIN_DELTA)"

# (e) window and region captures agree, ignoring the rounded corners
SHAVE=40
magick "$WIN_PNG" -shave "${SHAVE}x${SHAVE}" "$OUT_DIR/probe-window-inner.png"
magick "$REGION_PNG" -shave "${SHAVE}x${SHAVE}" "$OUT_DIR/probe-region-inner.png"
RMSE="$(magick compare -metric RMSE "$OUT_DIR/probe-window-inner.png" "$OUT_DIR/probe-region-inner.png" null: 2>&1 \
    | sed -E 's/.*\(([0-9.e+-]+)\).*/\1/' || true)"
ok="$(awk -v v="${RMSE:-1}" -v max="$AGREE_MAX" 'BEGIN { print (v + 0 < max) ? 1 : 0 }')"
check "window and region captures agree" "$ok" "normalised RMSE ${RMSE:-unknown}, need < $AGREE_MAX"

echo "probe images: $WIN_PNG $REGION_PNG $OUT_DIR/probe-capsule.png"
exit "$FAILED"
