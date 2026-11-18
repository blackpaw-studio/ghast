# Tart VM Runners — Spec

Status: approved by Evan 2026-11-18.

## Goal

When creating a runner, the user can choose to run it in an ephemeral Tart VM
(cirruslabs/tart) instead of directly on the host. Every job gets a fresh clone
of a macOS base image, which is destroyed after the job.

## Decisions

- **Ephemeral only.** One VM per job; registration via GitHub JIT config; VM
  deleted after the job. No persistent VM mode.
- **macOS guests only.** No Linux guests in v1.
- **Image choice:** curated list of cirruslabs macOS images plus "Custom…"
  (any OCI ref or local Tart VM name).
- **One sidebar entry = one slot.** Each VM runner loops clone → run one job →
  destroy. Parallelism means creating another entry.

## Requirements

### Creation (New Runner sheet)

1. A "Run in" choice: **This Mac** (default, current behaviour) or **Tart VM**.
2. With Tart VM selected, an image picker shows curated cirruslabs macOS images
   (base and Xcode variants) and a "Custom…" entry taking an OCI ref or local VM
   name. The curated list is a static list in code and excludes `-vanilla`
   images. The Custom field shows the hint "Image must include the Tart Guest
   Agent."; custom refs are not otherwise validated up front.
3. Tart detection: look for `tart` at `/opt/homebrew/bin/tart`,
   `/usr/local/bin/tart`, then the user's login-shell `PATH`. Tart must be
   ≥ 2.27.0 (needed for `tart exec`). If not found or too old, the Tart VM
   option is disabled and the sheet shows the Homebrew install command
   (`brew install openai/tools/tart`; reinstall wording when too old).
4. Creating a VM runner does not run `config.sh` and does not register anything
   on GitHub. It saves the config (scope, name, labels, runner group, image) and
   starts the slot.
5. Pre/post-job scripts and environment variables are hidden for VM runners.

### Lifecycle (per slot iteration)

1. If the image is not present locally, pull it, reporting progress in the log
   and status.
2. `tart clone <image> ghast-<runnerID>-<iteration id>`.
3. Boot it headless with the host runner cache shared into the guest.
4. Wait until the guest accepts commands (bounded timeout; failure → error
   state, clone cleaned up).
5. Request a JIT config (`generate-jitconfig`, repo or org per scope) with the
   runner's name suffixed by a short id, labels, group and work folder.
6. In the guest, extract the runner from the shared folder and run
   `./run.sh --jitconfig <config>`.
7. When the runner process exits (job done), stop and delete the clone, then
   start the next iteration while the slot should be running.
8. The macOS runner tarball (osx-arm64) is downloaded once to a host cache and
   reused; refreshed when a newer runner version is required.

### Concurrency

- Before booting, count running macOS VMs from `tart list` (including VMs not
  started by Ghast). If 2 are already running, do not start; the runner enters
  an error state whose message explains the 2-VM macOS limit.

### Stop, quit, crash recovery

- **Stop:** end the guest job, stop and delete the clone, delete the JIT
  runner registration via the GitHub API if it still exists.
- **Quit:** same for every VM runner; `applicationShouldTerminate` waits
  (`.terminateLater`) as it does for host runners.
- **Launch recovery:** on app launch, stop and delete leftover `ghast-*` clones
  and delete their JIT registrations (best effort; failures logged, not fatal).

### Logs and status

- Ghast lifecycle lines ("Pulling image…", "Cloning…", "Booting VM…",
  "Waiting for job", "Cleaning up") and the guest runner's output go to the
  runner's existing log file, so `LogTailer`/`RunnerOutputView` work unchanged.
- Status gains pulling, booting and cleaning-up phases, shown in the sidebar
  and detail header.

### Remove / Reconfigure

- **Remove:** stop the slot, delete any clone and JIT registration, drop the
  entry. No `config.sh remove`.
- **Reconfigure:** edits labels, runner group and image only; takes effect on
  the next iteration.

## Architecture

- New `RunnerBackend` seam (start, stop, liveness, log output).
  `BareMetalBackend` wraps the existing host path with no behaviour change.
  `TartBackend` implements the VM loop.
- `TartCLI` protocol wraps every `tart` invocation; production shells out via
  the existing process-launch seams, tests use a fake. Tests never run Tart.
- JIT config generation and runner deletion are added to
  `GitHubAPIServiceProtocol` and tested via the existing fake transport.
- `LocalRunner` gains a `backend` field (`host` | `tart(image:)`), decoded
  with default `host` so existing saved runners migrate untouched.

## Out of scope (v1)

Linux guests; per-runner CPU/RAM/disk settings (image defaults); pre/post-job
scripts and env vars for VM runners; multi-VM pools per entry; building custom
images.

## Open technical items (planner resolves via a spike)

- Guest command channel: decided 2026-11-18 — `tart exec` via the guest agent.
- Current Tart CLI flags (`run --no-graphics`, `--dir`, `list --format json`,
  `stop`, `delete`), current version and Homebrew tap.
- Official GitHub docs for `run.sh --jitconfig` and the fine-grained token
  permission needed for `generate-jitconfig` with Ghast's Device Flow token.

## Testing

- Unit: `TartBackend` loop with fake `TartCLI`, fake API and manual sleeper:
  happy path, pull-when-missing, boot timeout cleanup, 2-VM refusal, stop
  mid-job cleanup (clone deleted, JIT runner deleted), launch recovery.
- Migration: old `LocalRunner` JSON decodes with `backend == .host`.
- Snapshots: New Runner sheet with Tart VM selected, Tart missing, and the
  detail view in booting/pulling states.
- Live check: create a VM runner against a test repo, run a workflow, confirm
  the VM is created and destroyed and the runner disappears from GitHub.
