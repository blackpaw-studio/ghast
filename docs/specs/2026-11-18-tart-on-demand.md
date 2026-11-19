# On-demand Tart VM runners — Spec

Status: approved by Evan 2026-11-18. Replaces the always-on slot loop from
`2026-11-18-tart-vm-runners.md` (which keeps one idle VM running per started
runner). Evan will verify live on a release; there is no pre-build spike.

## Goal

A started VM runner runs **no VM while idle**. When GitHub has a queued job
for it, Ghast boots a fresh VM, the VM runs exactly one job, and is deleted.

## Decisions

- **No warm VMs.** After a job the VM is deleted; nothing waits idle.
- **Scale 0 → 2 per runner entry.** Two queued jobs boot two VMs in parallel.
  The macOS 2-VM limit is a **global** budget shared by all entries and
  includes VMs Ghast didn't start.
- **Targeting:** workflows use `runs-on: <runner name>`. The Labels field is
  removed for VM runners.
- **On-demand replaces always-on** for every VM runner; no mode toggle.

## Demand detection

- New `JobDemandSource` seam reporting how many jobs need a runner for this
  entry, plus a way to obtain a JIT config for a new runner.
- **Primary: `ScaleSetDemandSource`**, a Swift port of GitHub's runner
  scale-set protocol (reference: github.com/actions/scaleset, public preview).
  Creates or reuses a scale set named after the runner, in the runner's group,
  repo or org scope; holds a long-poll message session; acknowledges messages;
  derives demand from the message statistics (assigned jobs); obtains JIT
  configs from the scale set. Port shapes from the reference source; don't
  guess.
- **Fallback: `RESTPollingDemandSource`**, repo scope only. Used automatically
  when scale-set setup fails with an auth/permission error. Polls queued runs
  and their jobs with `If-None-Match`, counts queued jobs whose `labels`
  include the runner name (case-insensitive), and gets JIT configs via
  `generate-jitconfig` with the runner name as a label (plus defaults).
  Poll interval: 15 s. For org-scoped runners the auth failure is shown as an
  error instead.
- Either way `runs-on: <runner name>` works.

## VM lifecycle

- Started runner, no demand: status "Waiting for jobs", no VM.
- Demand > running VMs → boot more, limited by the global VM budget:
  pull image if missing (existing progress UI) → clone → boot → readiness
  probe → JIT config → `run.sh --jitconfig` → on exit stop, delete, delete the
  JIT runner if it still exists.
- Budget exhausted: the job stays queued on GitHub; status says
  "Waiting for a free VM slot".
- Transient errors (network, 5xx, tart failures, boot timeout) retry with the
  existing backoff; config errors stop the runner with an error, as today.
- Existing pieces stay: image pull + progress, tarball cache, guest script,
  leases, launch recovery, quit waiting for cleanup.

## Names

- Runner names for VM runners are validated against scale-set naming rules
  (take them from the reference source) in the New Runner sheet.

## UI

- Status: waiting for jobs / booting for a queued job / 1 job running /
  2 jobs running / waiting for a free VM slot / pulling (existing).
- New Runner sheet and Configuration tab show the `runs-on: <name>` line with
  a copy button; Labels field hidden for VM runners.
- Log: one stream; each VM's lines prefixed with a short VM id.
- Detail view shows a one-time note on migrated runners: labels no longer
  apply, use `runs-on: <name>`.

## Stop, quit, remove

- **Stop / Quit:** close the message session, stop and delete VMs, delete
  their JIT runners. The scale set stays, so queued jobs wait for Ghast.
- **Remove:** as Stop, then delete the scale set on GitHub (404 = gone).
- **Launch recovery:** unchanged (leftover `ghast-*` clones and leased JIT
  runners).

## Migration

- Existing VM runners become on-demand on first launch; saved labels are
  ignored (kept in storage for downgrade safety).

## Out of scope

Warm pools; more than 2 VMs; Linux guests; webhooks; enterprise scope.

## Testing

- Unit: scale-set client over fake transport (session create, long-poll 202
  empty, message ack, stats → demand, JIT config, session delete, auth error →
  fallback signal); REST source (ETag 304, label match, org → error);
  scheduler (demand 0 → no VM; demand 2 → 2 VMs; global budget shared across
  entries and foreign VMs; job finish → VM deleted, no replacement without
  demand; stop mid-boot cleanup).
- Snapshots: waiting-for-jobs, 2 jobs running, waiting for slot, New Runner
  sheet with `runs-on` line.
- Live (Evan, on a release): repo runner and org runner each pick up a queued
  job, VM appears only while the job runs, fallback path if the token is
  rejected.
