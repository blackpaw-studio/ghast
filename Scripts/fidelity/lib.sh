#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are consumed by the scripts that source this file
# Shared helpers for the fidelity scripts. Source this file; do not run it.
#
# Everything lands in build/fidelity/ (gitignored). The virtual display and the probe are
# dev-only tools: they run for the length of one script and are killed on exit.

FIDELITY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$FIDELITY_DIR/../.." && pwd)"
OUT_DIR="$REPO_ROOT/build/fidelity"
BIN_DIR="$OUT_DIR/bin"
DERIVED_DATA="$REPO_ROOT/build/DerivedData"
APP_BINARY="$DERIVED_DATA/Build/Products/Debug/Ghast.app/Contents/MacOS/Ghast"
DESIGN_DIR="$REPO_ROOT/docs/design/focus-redesign"

FIDELITY_PIDS=()

die() { echo "fidelity: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

cleanup_fidelity() {
    local pid
    for pid in "${FIDELITY_PIDS[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
    done
    FIDELITY_PIDS=()
}
trap cleanup_fidelity EXIT

# Registers a background process to be killed when the script exits.
track_pid() { FIDELITY_PIDS+=("$1"); }

# require_screen_recording: fails loudly unless Peekaboo reports Screen Recording granted.
# Captures go through Peekaboo (its Bridge holds the permission); `screencapture` is denied here.
require_screen_recording() {
    need peekaboo
    local report
    report="$(peekaboo permissions 2>&1)" || die "peekaboo permissions failed:
$report"
    grep -Eq 'Screen Recording[^:]*: *Granted' <<<"$report" \
        || die "Peekaboo does not report Screen Recording as granted; captures would be blank or denied:
$report"
}

# peek_window <CGWindowID> <out.png>: the window at native Retina resolution.
peek_window() {
    peekaboo see --no-elements --window-id "$1" --retina --path "$2" >/dev/null 2>"$OUT_DIR/peekaboo.err" \
        || die "peekaboo window capture of $1 failed: $(cat "$OUT_DIR/peekaboo.err")"
    [ -s "$2" ] || die "peekaboo wrote no image for window $1"
}

# peek_region <x,y,w,h in global points> <out.png>: a screen region at native Retina resolution.
peek_region() {
    peekaboo see --no-elements --mode area --region "$1" --retina --path "$2" >/dev/null 2>"$OUT_DIR/peekaboo.err" \
        || die "peekaboo region capture of $1 failed: $(cat "$OUT_DIR/peekaboo.err")"
    [ -s "$2" ] || die "peekaboo wrote no image for region $1"
}

# window_state <pid> <CGWindowID>: prints "<is_frontmost> <is_key>" (true/false) as Peekaboo sees it.
window_state() {
    peekaboo window list --pid "$1" --json 2>/dev/null | python3 -I -c '
import json, sys
want = int(sys.argv[1])
def walk(node):
    if isinstance(node, dict):
        if node.get("window_id") == want:
            yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)
for window in walk(json.load(sys.stdin)):
    print(str(window.get("is_frontmost")).lower(), str(window.get("is_key")).lower())
    break
else:
    print("missing missing")
' "$2"
}

# sheet_is_key <pid> <CGWindowID>: prints "true" when a frontmost, key window of the app lies
# inside the given window's frame: a sheet attached to it.
sheet_is_key() {
    peekaboo window list --pid "$1" --json 2>/dev/null | python3 -I -c '
import json, sys
want = int(sys.argv[1])
def walk(node):
    if isinstance(node, dict):
        if "window_id" in node:
            yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)
windows = list(walk(json.load(sys.stdin)))
parent = next((w for w in windows if w.get("window_id") == want), None)
def inside(inner, outer):
    a, b = inner.get("bounds") or {}, outer.get("bounds") or {}
    return all(k in a and k in b for k in "xy") and b["x"] <= a["x"] and b["y"] <= a["y"] \
        and a["x"] + a["width"] <= b["x"] + b["width"] and a["y"] + a["height"] <= b["y"] + b["height"]
print(str(parent is not None and any(
    w.get("window_id") != want and w.get("is_frontmost") and w.get("is_key") and inside(w, parent)
    for w in windows)).lower())
' "$2"
}

# window_is_active <pid> <CGWindowID> <allow_sheet>: frontmost and key, or, with a sheet open
# (allow_sheet=1), its sheet is frontmost and key.
window_is_active() {
    [ "$(window_state "$1" "$2")" = "true true" ] && return 0
    [ "${3:-0}" = "1" ] && [ "$(sheet_is_key "$1" "$2")" = "true" ]
}

# require_active_window <pid> <CGWindowID> [allow_sheet]: fidelity captures need the active window
# state (the mockups show active windows). If the app did not become frontmost by itself, ask
# Peekaboo to focus it once, then insist.
require_active_window() {
    local state attempt
    for attempt in 1 2 3 4; do
        window_is_active "$1" "$2" "${3:-0}" && return 0
        peekaboo window focus --window-id "$2" >/dev/null 2>&1 || true
        sleep 1
    done
    window_is_active "$1" "$2" "${3:-0}" && return 0
    state="$(window_state "$1" "$2")"
    peekaboo window list --pid "$1" --json > "$OUT_DIR/windows.json" 2>&1 || true
    die "window $2 (pid $1) is not frontmost and key (Peekaboo: '$state'); an inactive window would be captured; window list in $OUT_DIR/windows.json"
}

# gray_at <png> <x> <y>: 0-1 luminance of one pixel.
gray_at() { magick "$1" -colorspace Gray -format "%[fx:u.p{$2,$3}]" info:; }

# rgb_at <png> <x> <y>: "R G B" of one pixel, 0-255.
rgb_at() { magick "$1" -format "%[fx:round(255*u.p{$2,$3}.r)] %[fx:round(255*u.p{$2,$3}.g)] %[fx:round(255*u.p{$2,$3}.b)]" info:; }

# build_tool <name> <swiftc args...>: compiles into $BIN_DIR when the sources are newer.
build_tool() {
    local name="$1"; shift
    mkdir -p "$BIN_DIR"
    swiftc -O "$@" -o "$BIN_DIR/$name" || die "swiftc failed for $name"
}

# wait_for_line <logfile> <pattern> <timeout-seconds>: prints the first matching line.
wait_for_line() {
    local log="$1" pattern="$2" timeout="$3" waited=0 line
    while [ "$waited" -lt $((timeout * 10)) ]; do
        line="$(grep -m1 -E "$pattern" "$log" 2>/dev/null)" && { echo "$line"; return 0; }
        sleep 0.1
        waited=$((waited + 1))
    done
    return 1
}

# start_virtual_display: builds and starts the 2880x1800 (1440x900 pt) HiDPI display.
# Sets VD_ID and VD_ORIGIN ("x,y" in global points).
start_virtual_display() {
    build_tool virtual-display -import-objc-header "$FIDELITY_DIR/virtual-display/Bridging.h" "$FIDELITY_DIR/virtual-display/main.swift"
    local log="$OUT_DIR/virtual-display.log"
    : > "$log"
    "$BIN_DIR/virtual-display" > "$log" 2>&1 &
    track_pid $!
    local line
    line="$(wait_for_line "$log" '^virtual-display ready' 20)" || die "virtual display did not come up: $(cat "$log")"
    VD_ID="$(sed -E 's/.* id=([0-9]+).*/\1/' <<<"$line")"
    VD_ORIGIN="$(sed -E 's/.* origin=(-?[0-9]+,-?[0-9]+).*/\1/' <<<"$line")"
}

# Mockup PNG for a screen: Welcome and Settings hold two screens each, and so do the
# New Runner sheets.
mockup_name() {
    case "$1" in
        main) echo Main ;;
        configuration) echo Configuration ;;
        remote) echo RemoteRunner ;;
        error) echo ErrorRunner ;;
        first-run) echo FirstRun ;;
        welcome|device-code) echo Welcome ;;
        new-runner|new-runner-progress|new-runner-loading|new-runner-loaded) echo NewRunner ;;
        settings-general|settings-account) echo Settings ;;
        menu-bar) echo MenuBar ;;
        *) die "unknown screen '$1'" ;;
    esac
}

# parse_screen_args <screen> [--dark]: sets SCREEN, APPEARANCE ("" or "-dark").
parse_screen_args() {
    [ $# -ge 1 ] || die "usage: $(basename "$0") <screen> [--dark]"
    SCREEN="$1"; APPEARANCE=""
    mockup_name "$SCREEN" >/dev/null
    if [ "${2:-}" = "--dark" ]; then APPEARANCE="-dark"; fi
}
