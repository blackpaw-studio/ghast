# VM shell command and job scripts for Tart VM runners — Spec

Status: approved by Evan 2026-11-18. Builds on
`2026-11-18-tart-on-demand.md` (implement after it lands).

## 1. Copyable shell command

- The detail view lists each live VM of a VM runner with a copyable line
  `tart exec -it <clone name> zsh` and a copy button (reuse the existing
  pasteboard/copy pattern).
- A VM is listed from the moment its readiness probe succeeds until its
  cleanup starts. No VMs → no list.
- No embedded terminal and no launching Terminal.app.

## 2. Job scripts and environment variables inside the VM

- The Configuration tab shows the pre-job script, post-job script and
  environment variables for VM runners again, using the same `LocalRunner`
  fields and editors as host runners.
- Per VM boot, Ghast writes that runner's scripts and a `.env` into a
  per-runner host folder and shares it into the guest **read-only** as a
  second `--dir` share, separate from the runner tarball cache.
- The guest script copies the scripts into `~/actions-runner`, makes them
  executable, and writes `~/actions-runner/.env` with the user's variables plus
  `ACTIONS_RUNNER_HOOK_JOB_STARTED` / `ACTIONS_RUNNER_HOOK_JOB_COMPLETED`
  pointing at the copied scripts (only for scripts that are set), before
  `run.sh --jitconfig`. Same mechanism host runners use.
- Edits apply from the next VM boot; running VMs keep what they booted with.
- Environment variable values are never written to the runner log (same rule
  as the JIT config).
- Empty scripts/variables → no hook variables, no `.env` lines.

## Out of scope

Host-side lifecycle scripts; embedded terminal; keep-alive debug VMs.

## Testing

- Unit: share folder contents per runner config (scripts, `.env`, hook vars
  only when set, quoting of values with spaces/quotes/newlines); guest script
  argv includes the second read-only share; values absent from log output.
- Snapshot: detail view with two live VMs and their shell lines; VM
  Configuration tab with scripts/env visible.
- Live (Evan): pre-job script output appears in the job log; `tart exec -it`
  line opens a shell in a running VM.
