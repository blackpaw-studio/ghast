#!/bin/sh
# Removes the setuid softnet helper installed by install-softnet-helper.sh, and its folder when
# that is empty. Takes no arguments. Must run as root.
# Exit codes: 64 usage, 73 unsafe folder or helper, 77 not root.
set -eu
umask 022

HELPER_DIR="/usr/local/libexec/ghast"
HELPER="$HELPER_DIR/softnet"

if [ "$#" -ne 0 ]; then
  echo "usage: remove-softnet-helper.sh" >&2
  exit 64
fi

if [ "$(/usr/bin/id -u)" != "0" ]; then
  echo "must run as root" >&2
  exit 77
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

# Nothing there, nothing to remove.
if [ ! -e "$HELPER_DIR" ] && [ ! -L "$HELPER_DIR" ]; then
  exit 0
fi

# Refuse before deleting anything unless the whole chain is root-owned and nobody else can
# write into it: otherwise a swapped folder or link could aim rm at another file.
for p in "$HELPER_DIR" /usr/local/libexec /usr/local /usr /; do
  is_safe_folder "$p" || { echo "unsafe folder: $p" >&2; exit 73; }
done
if [ -L "$HELPER" ]; then
  echo "unsafe helper: $HELPER" >&2
  exit 73
fi

/bin/rm -f "$HELPER"
/bin/rmdir "$HELPER_DIR" 2>/dev/null || true
echo "removed $HELPER"
