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
        new-runner|new-runner-progress) echo NewRunner ;;
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
