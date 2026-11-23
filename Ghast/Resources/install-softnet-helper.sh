#!/bin/sh
# Installs the setuid softnet helper that lets Tart isolate VM networks.
# Usage: install-softnet-helper.sh SOURCE TARGET_DIR
# Must run as root. Exit codes: 64 usage, 66 bad source, 73 unsafe folder, 77 not root.
set -eu
umask 022

EXPECTED_DIR="/usr/local/libexec/ghast"

if [ "$#" -ne 2 ]; then
  echo "usage: install-softnet-helper.sh SOURCE TARGET_DIR" >&2
  exit 64
fi
SOURCE="$1"
dir="$2"

if [ "$dir" != "$EXPECTED_DIR" ]; then
  echo "unexpected target: $dir" >&2
  exit 64
fi

if [ "$(/usr/bin/id -u)" != "0" ]; then
  echo "must run as root" >&2
  exit 77
fi

real=$(/usr/bin/realpath "$SOURCE" 2>/dev/null) || {
  echo "source not found: $SOURCE" >&2
  exit 66
}
if [ ! -f "$real" ] || [ ! -x "$real" ]; then
  echo "source is not an executable file: $real" >&2
  exit 66
fi

/bin/mkdir -p "$dir"
/usr/sbin/chown root:wheel "$dir"
/bin/chmod 0755 "$dir"

for p in /usr/local/libexec/ghast /usr/local/libexec /usr/local /usr /; do
  mode=$(/usr/bin/stat -f '%Lp' "$p")
  if [ -L "$p" ] || [ ! -d "$p" ] \
    || [ "$(/usr/bin/stat -f '%u' "$p")" != "0" ] \
    || [ $((0$mode & 022)) -ne 0 ]; then
    echo "unsafe folder: $p" >&2
    exit 73
  fi
done

tmp=$(/usr/bin/mktemp "$dir/.softnet.XXXXXX")
trap '/bin/rm -f "$tmp"' EXIT
/bin/cp "$real" "$tmp"
/usr/sbin/chown root:wheel "$tmp"
/bin/chmod 4755 "$tmp"
/bin/mv -f "$tmp" "$dir/softnet"
trap - EXIT
echo "installed $dir/softnet"
