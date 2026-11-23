# Network isolation setup (softnet helper)

Date: 2026-11-22 · Status: draft · Extends `2026-11-19-tart-vm-resources.md`

## Problem

"Isolate network" boots VMs with `tart run --net-softnet`. Softnet needs root
to create its vmnet interface. Tart only offers to set this up in an interactive
terminal (`Run.swift:472`, `Softnet.swift:151-208`). Ghast runs Tart with no
terminal, so softnet exits with "root privileges are required … passwordless
sudo was not available" and every isolated boot fails. Today the user would have
to fix this by hand, and the obvious fixes are unsafe. Homebrew's
`/opt/homebrew/bin/softnet` is owned by the user, so setuid on it, or a sudoers
rule for it, lets any process running as that user swap the binary and get root.

## Goal

Ghast offers a one-time setup, behind the standard macOS admin password prompt,
that makes isolation work safely. It never boots an isolated VM until the setup
is valid, and never falls back to an unisolated VM.

## Design

**The helper.** Setup installs a root-owned, setuid copy of softnet at
`/usr/local/libexec/ghast/softnet`. The file is `root:wheel`, mode `4755`, and
every parent folder up to `/` is root-owned and not writable by group or others.
This follows Tart's own convention (a root-owned setuid softnet, which
`configureSUIDBitIfNeeded` accepts and skips). It needs no sudoers edit. Softnet
drops root to the calling user after it creates the interface (softnet README).

**Finding it.** Tart only finds softnet through `PATH` (`Softnet.swift:86-94`).
For isolated boots, Ghast launches `tart run` with
`PATH=/usr/local/libexec/ghast:<inherited PATH>`. Non-isolated boots are
unchanged.

**Readiness check** (`SoftnetHelperStatus`, pure logic over an injected file
inspector and process runner):
- `notInstalled`: there is no file at the path.
- `unsafe(reason)`: the file exists but is not root-owned, is not setuid, or a
  parent folder is writable by someone other than root. Ghast treats this as not
  set up and names the reason.
- `outdated(installed, available)`: the helper's `softnet --version` differs
  from the source softnet. The source is found the way Ghast finds `tart`:
  `/opt/homebrew/bin`, `/usr/local/bin`, then the inherited `PATH`, always
  skipping the helper folder. A GUI app's inherited `PATH` never includes
  Homebrew.
- `ready(version)`.
- `softnetMissing`: there is no source softnet and no helper.
  Show "Install Tart with Homebrew" (softnet comes with the `tart` formula).

The check runs when the Configuration tab opens, after setup, and right before
every isolated boot.

**Setup and update** (one action, `Set Up…` or `Update…`). Ghast runs one
privileged shell script through `NSAppleScript`
`do shell script … with administrator privileges`, which shows the system
password prompt. The script copies the source softnet (following symlinks) into a temp file inside the target folder, sets
owner and mode, and renames it into place atomically. It also creates the
folder (`root:wheel`, `0755`) if it's missing. The paths are passed as quoted
arguments, never put into the script text. After the script, the readiness
check runs again. Cancelling the password prompt is not an error: the status
stays as it was.

**Removal.** Settings › General gets a "VM network isolation" row showing the
status, with `Remove Helper…` behind a confirmation. It does a privileged `rm`
of the file and of the folder if the folder is empty. Runners with isolation on
then show the setup state again.

**Boot behaviour** (changes the base spec):
- If isolation is on and the status is `ready` or `outdated`, the boot runs with
  the helper on `PATH`. When `outdated`, the boot uses the installed copy and the
  runner logs one line suggesting Update.
- If isolation is on and the status is anything else, the VM is not cloned. The
  runner logs one line (`Network isolation isn't set up on this Mac; open
  Configuration to set it up`) and the entry shows an error state. Ghast doesn't
  retry until the status changes (it re-checks on the next demand). This
  replaces the base spec's "boot fails and retries".

**UI.** In the Configuration tab's Resources group:
- The "Isolate network" toggle can always be switched on.
- When the status isn't `ready`, a row under the toggle shows it
  ("Needs a one-time setup", "Helper is unsafe: …", "Softnet was updated",
  "Install Tart with Homebrew") next to the matching button (`Set Up…`,
  `Update…`).
- The help line says isolation blocks the local network and keeps internet
  access, and that setup asks once for an administrator password.

## Step 0: spike (gates the design)

On Dionysus, by hand in Terminal, with Evan entering the password:

1. Install the helper the way the script will. `PATH=/usr/local/libexec/ghast:$PATH tart run --no-graphics --net-softnet` on a clone boots with no prompt.
2. `tart exec` and both `--dir` shares work.
3. `curl https://github.com` works from the guest. `curl -m 5` to `10.0.2.10`,
   `10.0.4.10` and the host's LAN IP fails.
4. A second isolated VM can't reach the first.
5. Record `codesign -dv` of the Homebrew softnet. If it's signed by a known
   team, the setup script checks that signature before copying (otherwise note
   it as an accepted risk: setup trusts the user-owned binary at the moment the
   admin approves).

If step 3 shows LAN access by default, Ghast passes explicit `--net-softnet-block`
ranges for RFC 1918 and link-local, and the spike checks again with them.

## Testing

- `SoftnetHelperStatus`, against a fake file inspector and process runner: each
  status, including a group-writable parent, a symlinked helper (unsafe), and
  version mismatch.
- Privileged runner, faked: setup builds the script with the quoted arguments,
  a cancelled prompt leaves the status unchanged, and removal calls `rm` only on
  the known path.
- Backend:
  - An isolated boot with status `ready` launches `tart run` with the helper
    folder first on `PATH`.
  - A non-isolated boot's environment is unchanged.
  - Not ready: there's no clone, the log line appears, and there's no retry
    loop.
  - `outdated` boots and logs.
- Snapshots: the Resources group in the `notInstalled`, `unsafe` and `outdated`
  states, plus the Settings › General row.
- Security review (`review.security`) of the whole diff before merge.

## Out of scope

SMAppService or launchd privileged daemons, sudoers edits, per-runner allow or
block lists, and auto-updating the helper without asking.

## Step 0 results

Run 2026-11-22 on Dionysus by the implementer as `evan`, after Evan installed the helper with `Ghast/Resources/install-softnet-helper.sh`. Tart 2.42.0, softnet 0.26.0-816f07a, image `macos-tahoe-base:latest`, two fresh clones, environment `env -i HOME USER PATH=/usr/local/libexec/ghast:/usr/bin:/bin:/usr/sbin:/sbin`. No VM was running beforehand. Both clones were stopped and deleted afterwards; the helper stays installed.

| Check | Result |
|---|---|
| 1. File modes | `root:wheel -rwsr-xr-x` helper, `drwxr-xr-x root:wheel` for `/usr/local/libexec/ghast` and `/usr/local/libexec`. |
| 2. `--version` | Helper and `/opt/homebrew/bin/softnet` both print `softnet 0.26.0-816f07a`, exit 0, equal. |
| 3. Signature | Homebrew softnet is `Signature=adhoc`, `flags=0x20002(adhoc,linker-signed)`, `TeamIdentifier=not set`. No team signature, so setup has no signature check (accepted risk, see below). The installed copy has the same ad hoc signature. |
| 4. Boot | `tart run --no-graphics --net-softnet --dir=… --dir=…` booted with no prompt and no sudo error (log empty). `tart exec ghast-sn1 true` answered on the first try. |
| 5. Shares and network | Both `--dir` shares listed with their files. From the guest, `https://github.com` returned 200. `curl -m 5` to `10.0.2.10`, `10.0.4.10` and the host's en0 IP `10.0.4.16` each timed out (curl exit 28). `10.0.4.10` answers 200 from the host, so that failure is the isolation. `10.0.2.10` returned nothing from the host either (nothing listens on port 80), so its failure shows less. Softnet's default blocks private ranges: no `--net-softnet-block` flags are needed. |
| 6. VM to VM | From `ghast-sn2` (192.168.97.194), `curl -m 5` to `ghast-sn1` (192.168.29.218) timed out and `ping -c 2 -t 5` lost 100%. `ghast-sn2` reached github.com (200). |
| 7. Control | With `PATH=/usr/bin:/bin:/usr/sbin:/sbin` only, `tart run` exits 1 with `Error: InitializationFailed(why: "softnet not found in PATH")`. The `PATH` entry is what makes isolation work. |

Decisions from the plan's table: no block flags (check 5), no signature check (check 3, ad hoc), no escalation. Accepted risk: setup copies a user-owned, ad hoc signed binary, so a process already running as the user could swap it before the admin approves.

Note: `ping` is not on the guest's default `PATH`; use `/sbin/ping`.
