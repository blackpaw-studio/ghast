# VM Job History: see what each VM runner ran

Status: draft, 2026-11-27. Evan chose: VM runners only, a Jobs tab per runner (option A), and clicking a job opens the run on GitHub (no local per-job log). There are no failure notifications.

## Problem

A VM runner runs one job per throwaway VM. Ghast reads each job's name and result from the runner's output (`OutputParser`, the `JobRecord` type), but only in memory: the record is gone at quit, and it has no repo, workflow or link. To find what a runner did, you open GitHub and search.

## Behaviour

### Jobs tab

- A third detail tab, **Jobs**, after Output and Configuration. Only VM runners (`.tart` backend) show it. Host runners keep their two tabs, and a host runner selected while the saved tab is Jobs shows Output.
- One row per job, newest first:
  - The result: a symbol plus text (Succeeded, Failed, Cancelled, Running, Didn't start, Unknown). Colour follows the existing status colours.
  - The job name (the runner's `Running job: <name>`).
  - `<workflow> · <owner/repo>`.
  - Start time (relative, with the absolute time as help text) and duration. A running job's duration counts up live.
- Click (or Return) on a row opens the run in the browser: `https://github.com/<owner>/<repo>/actions/runs/<run id>/attempts/<attempt>`. A context menu has **Open Run on GitHub** and **Copy Run URL**. A row with no run (Didn't start, or the run info never arrived) does nothing and shows no menu.
- **Didn't start** rows: the VM failed before a job started (pull, clone, boot, registration or guest script). The row shows the first error line that `TartBackend` already logs for that failure, in place of `<workflow> · <repo>`.
- **Unknown**: the VM ended (crash, Stop, quit) after the job started but before the runner reported a result.
- Empty state: `No jobs yet. Jobs this runner runs appear here.`

### What a job record holds

`id` (the VM's 6-hex id), `jobName?`, `workflowName?`, `repository?` (`owner/repo`), `runID?`, `runAttempt?`, `result`, `startedAt`, `finishedAt?`, `failureMessage?` (Didn't start only).

- The record is created when the VM is claimed for a job. Its start time is the time the record was created, so a Didn't-start row has one too.
- The name and result come from the runner's own output lines, as today.
- The repo, workflow, run id and attempt come from inside the VM. Ghast adds its own `ACTIONS_RUNNER_HOOK_JOB_STARTED` script. The script records `GITHUB_REPOSITORY`, `GITHUB_WORKFLOW`, `GITHUB_RUN_ID` and `GITHUB_RUN_ATTEMPT` where Ghast can read them before the VM is deleted, then runs the user's pre-job script (if any) with the same exit-code behaviour as today. The user's script still sees the same environment, and its output still goes to the job log. The planner picks how the values reach the host (the job share, `tart exec`, or a marker line) and must justify the choice.
- **Untrusted input:** a workflow controls its VM, so everything read from the guest is untrusted. `repository` must match `^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$`. For an org runner the owner must be the runner's org, and for a repo runner it must be the runner's repo, case-insensitively. Run id and attempt must be positive integers. Workflow and job names are clipped to 200 characters with control characters removed. A value that fails these checks is dropped, so the row has no link; the rest of the record stays. Ghast builds the URL itself and never takes a URL from the guest.

### Storage

- `~/.ghast/history/<runner id>.json`. The folder is 0700 and the files are 0600. Each write is atomic (write to a temp file, then rename), following `CacheStore`'s index writer. The store is injected, and tests and the design fixture use an in-memory store.
- Each runner keeps its newest 200 records. Older ones are dropped on write.
- The store writes when a record is created, when the run info arrives, and when the record finishes.
- At launch, a record still marked Running becomes Unknown with no `finishedAt`. Its VM is gone because Ghast cleans up leftover clones.
- Remove deletes the runner's history file. Stop does not.
- A file that won't decode is renamed `<runner id>.json.corrupt`, with one log line, and the history starts empty. Nothing is silently lost.

## Testing

- Unit tests:
  - Record lifecycle through `TartBackend` with fakes: claimed → Didn't start; claimed → started → Succeeded/Failed/Cancelled; ended without a result → Unknown.
  - The guest-value validation table: good and bad repo, owner mismatch, a non-numeric run id, an oversized name, control characters.
  - URL building.
  - The store: cap, atomic write, permissions, the corrupt file, Running → Unknown at load, delete on Remove.
- The guest script test covers chaining the user's pre-job script: it runs, it sees the same environment, and a failing exit code is kept.
- Snapshots: `vmJobs` (one row of each result, including Running) and `vmJobsEmpty`, in light and dark. The design fixture gains seeded history for the main screen's VM runner.

## Out of scope

- Failure notifications.
- Host (`run.sh`) runners.
- History across runners in one window.
- A local log per job.
- Using the scale-set JobStarted/JobCompleted messages (the REST fallback has none, and the guest already has what's needed).
- Filtering and search.
