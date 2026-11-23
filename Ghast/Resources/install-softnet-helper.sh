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

real=$(/bin/realpath "$SOURCE") || {
  echo "source not found: $SOURCE" >&2
  exit 66
}
if [ ! -f "$real" ] || [ ! -x "$real" ]; then
  echo "source is not an executable file: $real" >&2
  exit 66
fi

# BEGIN shared folder checks (identical in install-softnet-helper.sh and remove-softnet-helper.sh)
# has_write_acl PATH: an ACL entry that allows anyone to write, add files or folders, delete,
# or change attributes, security or owner. Deny entries (macOS puts `deny delete` on some
# folders) and read-only allow entries are fine.
has_write_acl() {
  /bin/ls -led "$1" | /usr/bin/awk '
    NR > 1 && NF >= 3 && $(NF - 1) == "allow" {
      n = split($NF, perms, ",")
      for (i = 1; i <= n; i++)
        if (perms[i] ~ /^(write|append|delete|delete_child|add_file|add_subdirectory|writeattr|writeextattr|writesecurity|chown)$/) found = 1
    }
    END { exit found ? 0 : 1 }'
}

# is_safe_folder PATH: a real directory (not a symlink), owned by root, with no group/other
# write bit and no ACL that grants write.
is_safe_folder() {
  p="$1"
  [ ! -L "$p" ] && [ -d "$p" ] || return 1
  [ "$(/usr/bin/stat -f '%u' "$p")" = "0" ] || return 1
  mode=$(/usr/bin/stat -f '%Lp' "$p")
  [ $((0$mode & 022)) -eq 0 ] || return 1
  if has_write_acl "$p"; then return 1; fi
  return 0
}
# END shared folder checks

# Check parents that already exist before touching anything. A missing parent is fine:
# mkdir -p creates it as root under umask 022.
for p in /usr/local/libexec /usr/local /usr /; do
  if [ -e "$p" ] || [ -L "$p" ]; then
    is_safe_folder "$p" || { echo "unsafe folder: $p" >&2; exit 73; }
  fi
done

# A pre-planted symlink or file at the target would make chown/chmod hit something else.
if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
  echo "unsafe folder: $dir" >&2
  exit 73
fi

/bin/mkdir -p "$dir"
/usr/sbin/chown -h root:wheel "$dir"
/bin/chmod 0755 "$dir"
# chmod keeps ACLs: clear any the folder already had before anything is written into it.
/bin/chmod -N "$dir"

# Final check over every folder on the path.
for p in /usr/local/libexec/ghast /usr/local/libexec /usr/local /usr /; do
  is_safe_folder "$p" || { echo "unsafe folder: $p" >&2; exit 73; }
done

tmp=$(/usr/bin/mktemp "$dir/.softnet.XXXXXX")
trap '/bin/rm -f "$tmp"' EXIT
/bin/cp "$real" "$tmp"
/usr/sbin/chown root:wheel "$tmp"
/bin/chmod 4755 "$tmp"
/bin/chmod -N "$tmp"
/bin/mv -f "$tmp" "$dir/softnet"
trap - EXIT
echo "installed $dir/softnet"
