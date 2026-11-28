# VM Job History: implementation plan

Spec: `docs/specs/2026-11-27-vm-job-history.md`. If this plan and the spec disagree, the spec wins. Every test is Swift Testing, written first and seen to fail before the code that makes it pass.

**Test command** (`<Suite>` changes per step; run `xcodegen` first whenever a file is added):
`xcodebuild test -project Ghast.xcodeproj -scheme Ghast PRODUCT_BUNDLE_IDENTIFIER=net.evancoleman.ghast.testhost -only-testing:GhastTests/<Suite>`

## Decisions

1. **Transport: a marker line on the guest exec stream that `runGuest` already reads.** Ghast's own `JOB_STARTED` hook writes the four values, each base64-encoded, to a guest-local file (`$HOME/.ghast-run-info`, written to a temp file and then `mv`'d). A small background watcher that the guest script starts before `run.sh` polls for that file once a second, prints one line, `<stamp> ghast: run-info repository=<b64> workflow=<b64> run_id=<b64> run_attempt=<b64>`, and exits. The script kills the watcher after the `run.sh` pipeline and still exits with `run.sh`'s status. Why:
   - It adds no host input surface. The exec stream already carries guest-controlled bytes into Ghast. A **writable job share** would let a workflow fill the host's disk with no possible quota, plant symlinks or FIFOs for the host to follow, and tamper with the folder that holds the scripts and `.env`. A **`tart exec` read** is one more guest-controlled process, and `ProcessRun` buffers its output with no cap, so it would need its own cap and deadline. It also needs retry timing to catch the hook, and a VM that crashes or is stopped gives no info.
   - It arrives live, within about 1 s of the hook, so a Running row has its workflow and repo, and a later Stop or crash still leaves a row with a link.
   - It runs before any workflow step, because the `JOB_STARTED` hook comes first. The host takes **only the first** `run-info` line per VM, so a later forged line is ignored. A step can still race the watcher in its first second, but validation limits that to a link to another run under the runner's own owner (accepted risk, below).
   - The hook's own stdout goes to the job log, so it cannot write the marker itself. The watcher writes to the guest script's stdout instead. Passing a file descriptor down was rejected: daemons started by steps would inherit it, hold the pipe open, and the exec would never end.
2. **Attribution is by stream, not by parsing the shared log.** `execStreaming` gains an `onLine` callback. `PrefixedLogSink` calls it once per complete line, without the prefix, synchronously on the reading thread. Each VM's guest exec has its own sink, so its lines belong to that VM by construction, and the `[vm id]` prefix is never parsed again. The callback feeds a lock-protected, per-VM `GuestJobTracker` (`Sendable`). Because `onTermination` calls `sink.finish()` before `onExit`, the tracker already holds every line when the guest exit reaches the main actor. Finalization reads it synchronously, so no "completed" line can arrive after the row is written as Unknown. Tailing the log through `RunnerActivityStore` was rejected for three reasons: it tails only tracked runners, its clear offsets drop lines, and its `lastIndex(name ==, result == nil)` match mixes up two VMs running jobs with the same name.
3. **When a record is created.** The spec's "claimed" has to cover pull, clone and boot failures, but `hasClaimedJob` is only set after boot. So: when `bootAndRun` passes the isolation gate, the VM keeps `historyStartedAt = clock.now` in memory. The record is **written** at the first of two points: `reserveSlot` succeeding (`begin`) or a failure before that (one Didn't-start write). `.noSlot` and `.isolationNotReady` write nothing, so a 15 s slot recheck doesn't touch the disk. `.abandoned`, a Stop before a job started, and a clean exit (0) with no `Running job:` line all discard the record: no job ran and nothing failed. A non-zero exit or a non-cancellation error before a job started gives **Didn't start**. After `Running job:`, ending with no result gives **Unknown** with `finishedAt` set to the time the VM ended. The parser's `.other` result also maps to Unknown. Flagged for the orchestrator in the open questions.
4. **Didn't-start message**: the first line of `"Error: " + error.localizedDescription`, the same text `finished` already logs. A non-zero exit uses `TartBackendError.runnerExited(code)`'s description. Clipped to 200 characters.
5. **The pre-job chain sources the user's script.** Ghast's hook ends with `. "$PWD/pre-job.sh"` after it unsets its own `GHAST_*` variables. The runner runs Ghast's hook exactly as it ran `pre-job.sh` before, so the user's script keeps the same shell options and environment, and its `exit N` or failing command still decides the hook's status. Ghast's own writes are `|| true`, so a write failure never fails the job. The post-job hook is unchanged.
6. **Ownership**: `JobHistory` (`@MainActor @Observable`) holds the records and writes through an injected `JobHistoryStoring`. It is built in `AppDependencies` and injected into `TartBackend` (to record), into `RunnerService` (to delete on Remove) and into the views. `TartBackend` and `RunnerService` take a defaulted no-op so existing tests compile unchanged.

## Steps

### 1. Record model, validation and URL (pure)
- New `Ghast/Models/JobHistory/JobHistoryRecord.swift`: `struct JobHistoryRecord: Codable, Sendable, Equatable, Identifiable`, with the fields exactly as the spec lists them. `enum JobHistoryResult: String, Codable { succeeded, failed, cancelled, running, didNotStart, unknown }`. `var runURL: URL?` is built only from `repository`, `runID` and `runAttempt`, as `https://github.com/<repo>/actions/runs/<id>/attempts/<n>`, and is nil if any of them is missing.
- New `GuestRunInfo.swift`: `static func validated(_ raw: [String: String], scope: RunnerScope) -> GuestRunInfo` applies the spec's rules:
  - the repository regex, plus an owner check: an org runner needs owner == login; a repo runner needs repo == fullName. Both comparisons ignore case.
  - run id and attempt must be positive integers.
  - the workflow name is clipped to 200 characters, and control characters are removed.
  - A failing field is dropped; the other fields stay.
  - The same clip-and-strip helper is used for job names.
  - `parseMarker(_ text: String) -> [String: String]?` base64-decodes the `ghast: run-info` line.
- Failing tests, `JobHistoryRecordTests` and `GuestRunInfoTests`:
  - a parameterised validation table: a good repo; a bad character; no slash; owner mismatch for an org runner and for a repo runner; a case-only difference passes; a non-numeric run id; 0 and a negative attempt; a 300-character name; control characters; bad base64.
  - URL building, and that there is no URL when the attempt is missing.

### 2. Store
- New `Ghast/Services/JobHistory/JobHistoryStore.swift`: `protocol JobHistoryStoring { load(runnerID:) -> [JobHistoryRecord]; save(_:runnerID:) throws; delete(runnerID:) throws }`.
- `FileJobHistoryStore(root:)`, at `~/.ghast/history`:
  - The folder is created 0700. Each write goes to a temp file in that folder, is set to 0600, then is renamed over the target, following `CacheStore.saveIndex`.
  - A file that won't decode is renamed to `.corrupt`, gets one `Logger` line, and loading returns `[]`.
  - Runner ids are path components; reject anything that isn't the id shape.
- `InMemoryJobHistoryStore` for tests and the fixture.
- Failing tests, `JobHistoryStoreTests` (temporary directory): round trip; folder and file modes; no temp file left behind; corrupt → `.corrupt` file plus an empty result; delete; a traversal id is rejected.

### 3. `JobHistory` model
- New `JobHistory.swift`. Its methods:
  - `records(for:)`, newest first, loaded lazily. Loading turns `running` into `unknown` with `finishedAt` nil and saves.
  - `begin(runnerID:vmID:at:)`
  - `didNotStart(runnerID:vmID:startedAt:message:)`
  - `jobStarted(...name:)`
  - `runInfo(...GuestRunInfo)`
  - `finish(...result:at:)`
  - `discard(...)`
  - `delete(runnerID:)`
- Every change saves and caps the list at 200, dropping the oldest.
- `delete` leaves a tombstone, so a VM still ending after Remove can't create the file again.
- Save errors are logged, never thrown, so a VM job never fails over history.
- Clock injected.
- Failing tests, `JobHistoryTests` with the in-memory store and a fixed clock: the cap at 201; Running → Unknown at load; writes happen at create, run-info and finish; delete plus a late `finish` writes nothing.

### 4. Guest script: Ghast's hook and the watcher
- `TartGuestScript.swift`:
  - New `static let jobStartedHook` (bash text). The guest script always writes it as `ghast-job-started.sh` and points `ACTIONS_RUNNER_HOOK_JOB_STARTED` at it.
  - When the job share has `pre-job.sh`, it is copied in as today and the hook sources it (Decision 5).
  - New `static let runBlock`: `rm -f` the info file, start the watcher (`sleep 1 >/dev/null`, `head -c 4096`, one line, then exit), run the `run.sh` pipeline, save `PIPESTATUS[0]`, kill the watcher, and exit with that status.
- Failing tests in `TartGuestScriptTests`, in the existing style (run under `/bin/bash` in a temp folder):
  - Run the hook with `GITHUB_*` and a custom variable set, plus a fake `pre-job.sh` that prints its environment and `exit 3`. Expect the info file to decode to the four values, the user script to see the same variables (including the custom one), status 3, and none of Ghast's lines in the hook's output.
  - Without `pre-job.sh`, expect status 0.
  - `runBlock` with a fake `run.sh` that runs the hook and exits 7: expect exactly one `ghast: run-info` line on stdout, exit 7, and no watcher still running when the block returns (bounded by a test timeout, no real waits beyond the 1 s poll).

### 5. Line callback and tracker
- `PrefixedLogSink(file:prefix:onLine:)`: call `onLine` with each complete line, before the prefix is added. `finish()` also delivers a trailing partial line.
- `TartCLI.execStreaming(..., onLine:, onExit:)`: update `ProcessTartCLI`, `FakeTartCLI` (which lets tests feed lines) and `FixtureTartStorage`.
- New `GuestJobTracker` (`final class`, `Sendable`, `NSLock`). It reads the job event from each line through a new `OutputParser.jobEvent(in rawLine:) -> JobLineEvent?`, which strips the guest stamp and the runner's own prefix and reuses `jobStartPrefix` and `completedJob`. It also reads the first `run-info` marker. It keeps a snapshot: `jobName`, `result`, `runInfo`. A `changes` callback goes to the main actor so changes are saved live.
- Failing tests:
  - `PrefixedLogSinkTests`: `onLine` gets whole, unprefixed lines.
  - `OutputParserTests`: `jobEvent` on stamped lines.
  - `GuestJobTrackerTests`: start then result; only the first marker counts; a second `Running job` is ignored.

### 6. `TartBackend` records the lifecycle
- `TartBackend.init(..., history: any JobHistoryRecording = NoJobHistory())`, where `JobHistory` conforms to `JobHistoryRecording`. `VMRun` (`OnDemandEntry.swift`) gains `historyStartedAt: Date?`, `isHistoryBegun` and `tracker`.
- Hook points:
  - `bootAndRun`: after the gate, set `historyStartedAt`; after `reserveSlot`, call `begin`.
  - `runGuest`: pass `vm.tracker`'s `onLine`.
  - `runVM`: after the outcome and before `cleanUpUncancelled`, call a new `recordOutcome(vm, outcome, runner)` that applies Decisions 3 and 4 and validates run info with `runner.scope`.
- Failing tests, new `TartBackendJobHistoryTests`, built on the existing `TartBackendOnDemandTests` harness with `FakeTartCLI` feeding lines:
  - claimed, then the clone fails → Didn't start with the error text.
  - started → Succeeded, Failed and Cancelled, each with run info and a URL.
  - started, then Stop → Unknown.
  - started, then the VM process dies → Unknown.
  - noSlot and abandoned → no record.
  - an org-mismatched marker → no link; the rest is kept.
  - two VMs at once with the same job name and different results → each record gets its own result.
- Existing suites: `TartBackendTests`, `TartBackendOnDemandTests`, `TartBackendStopTests` and `TartBackendRetryTests` stay green.

### 7. Remove deletes history
- `RunnerService.init(..., jobHistory: any JobHistoryDeleting = NoJobHistory())`. `removeLocalRunner` and `removeAllLocalRunners` call `delete`. Check that every Remove path (`RunnerRemover.remove`, `removeFromThisMacOnly` and `RunnerFlowCoordinator`) reaches `removeLocalRunner`.
- Failing test in `RemoveRunnerTests`: Remove deletes the file; Stop keeps it.

### 8. Wiring
- `GhastApp.swift` `AppDependencies`: `JobHistory(store: FileJobHistoryStore(root: ~/.ghast/history), clock:)`, passed to `TartBackend` and `RunnerService` and put in the environment. Do the first lazy load for every VM runner during launch, before recovery, so Running → Unknown happens at launch.
- Fixture (`FixtureDependencies`): an in-memory store seeded from a new `Ghast/Fixture/FixtureJobHistory.swift` for the main screen's VM runner. It has one row of each result (Running started 3 min before the fixture clock), one Didn't-start row with a pull error, and one Unknown row.
- Failing tests: `FixtureSafetyTests`, where fixture mode never creates `~/.ghast/history`; `FixtureDataTests`, where the seeded history has every result.

### 9. Jobs tab UI
- `MainSelection.swift`: `DetailTab.jobs` ("Jobs") and `static func tabs(isVM: Bool) -> [DetailTab]`.
- `MainToolbar` lists `tabs(isVM:)`. `FocusMainView.tab`'s getter maps `.jobs` to `.output` for a host runner, without rewriting `storedTab`.
- New `Ghast/Views/Focus/JobsTabView.swift` (`JobsTabView`, `JobHistoryRow`):
  - The result symbol and text use the existing `FocusColor` status colours.
  - Each row shows the name, then `<workflow> · <repo>`, or `failureMessage` for Didn't start.
  - The start time is relative to an injected `now`, with the absolute time as `.help`. The duration uses `DurationFormat`.
  - Running rows sit inside `TimelineView(.periodic(by: 1))` in the app. Snapshots pass a fixed `now`.
  - Click and Return (`onKeyPress(.return)` on the selection) call `openURL(record.runURL)`. The context menu is `Open Run on GitHub` and `Copy Run URL` (`NSPasteboard`). A row with no URL gets neither.
  - The empty state uses the spec copy.
- `RunnerDetailViews.swift`: add `case .jobs`.
- Failing test: `MainSelectionTests`, where `tabs(isVM: false)` has no Jobs and the getter falls back to Output. No logic tests for views (per CLAUDE.md, the snapshots cover them).

### 10. Snapshots
- `FocusMainSnapshotTests.State`: add `vmJobs` and `vmJobsEmpty`, rendered with the fixture clock's `now`.
- Record: `TEST_RUNNER_SNAPSHOT_RECORD_MODE=true xcodebuild test … -only-testing:GhastTests/FocusMainSnapshotTests PRODUCT_BUNDLE_IDENTIFIER=net.evancoleman.ghast.testhost`, then run it again without the variable and confirm green.
- Inspect the 4 new PNGs at native pixels (light and dark). Existing PNGs must not change, except that the toolbar segment of every VM state gains "Jobs". If that changes existing VM PNGs, re-record them on purpose and say so in the commit.
- Update the CLAUDE.md snapshot list and add a Jobs bullet under Runner Management.

### 11. Integration gate
- Check the load first. Run the full suite under `heavy` in the background.
- Then run `Scripts/fidelity/capture.sh main` with the Jobs tab selected, for a visual check.

## Risks and accepted limits

- **A forged line in the first second.** A workflow step that rewrites the info file before the watcher's first read, or a process that forges the marker before the real one, can point the link at another run under the same owner. It can't point at any other owner, and Ghast builds the URL itself. Accepted.
- **The watcher depends on `kill`.** If the watcher outlives the pipeline, the exec can't end. Step 4 has a test that the block returns, and `sleep` writes nowhere, so a leftover `sleep` doesn't hold stdout.
- **The fixed path `$HOME/.ghast-run-info`.** The clone is fresh for each job, so nothing is left from an earlier job. `rm -f` at start covers an image that ships the file.
- **A long `Running job:` line** gets the existing unbounded `PrefixedLogSink` pending buffer. The risk was there before; nothing new.
- **`TartCLI` protocol change.** Every conformer is in Step 5.

## Open questions (orchestrator)

1. Decision 3 reads "claimed" as "passed the isolation gate, written when the slot is reserved or on an earlier failure". It discards abandoned VMs, a Stop before a job started, and an exit 0 with no job. Confirm, or narrow it.
2. The `ghast: run-info …` line is visible in the Output tab (base64 values). Hiding it in `OutputParser` is small but outside the spec; leave it unless Evan objects.
3. GitHub's docs say job hooks see the job's `GITHUB_*` variables. If the first real VM job shows `GITHUB_RUN_ATTEMPT` missing, the rows just have no link (validation drops it). Worth one real job at the gate, not a blocker.

## Orchestrator resolutions (2026-11-27)

1. Decision 3's reading of "claimed" is confirmed as written.
2. Hide the `ghast: run-info` marker from the Output tab: `OutputParser` drops those lines from display. Add one test case to `OutputParserTests` in Step 5.
3. Accepted. Check that the link appears on the first real VM job after release; don't block the merge on it.
