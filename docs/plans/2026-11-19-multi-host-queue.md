# Plan: Multi-host VM runners (queue lease, sleep release, standby role)

Spec: `docs/specs/2026-11-19-multi-host-queue.md` (the source of truth). Branch: `feat/multi-host-queue`.
- Run `xcodegen` after adding files.
- Verify each step with `xcodebuild test -project Ghast.xcodeproj -scheme Ghast -destination platform=macOS -only-testing:GhastTests/<Suite>`.
- Commit after each step, with an emoji prefix.

## Design decisions
- **Queue status:** `enum JobQueueStatus: Sendable, Equatable { case connecting, holding, heldElsewhere, released(ReleaseReason), noQueue }` with `ReleaseReason { sleep, handoff }`.
  - `noQueue` covers the REST fallback, so the UI can say the queue doesn't apply.
  - `OnDemandState.queue: JobQueueStatus`, default `.connecting`.
- **Source contract:** `run(onDemand:)` becomes `run(_ context: DemandRunContext)`.
  - `DemandRunContext { onDemand: @MainActor (Int)->Void; onQueue: @MainActor (JobQueueStatus)->Void; role: @MainActor ()->QueueRole; idleSince: @MainActor ()->Date? }`.
  - Role and idle state are read live, so a role change applies without a restart.
- **Where the logic lives:** the 409 cadence and the standby yield and handoff live in `ScaleSetDemandSource`.
  - A 409 is handled inside `run` and never thrown, so `TartBackend.runDemand`'s backoff covers only other errors.
  - Timings are injected through `DemandSourceFactory` (with the clock) as `struct QueueTiming`:
    - `primaryConflictRetry` = 10 s
    - `standbyConflictRetry` = 5 s
    - `standbyConflictRetryMax` = 60 s
    - `standbyYieldAfter` = 5 min
    - `handoffWindow` = 30 s
- **Yield rule:** the standby yields when it holds the queue and `now - max(idleSince, heldSince) >= standbyYieldAfter`.
  - Taking the later of `idleSince` and `heldSince` stops it yielding again right after it takes the queue back.
- **Idle tracking:** `TartBackend` owns `OnDemandEntry.idleSince`.
  - It is set when `demand == 0 && vms.isEmpty` and cleared otherwise.
  - It is updated in `demandChanged`, `reconcile` and `remove(vm)`.
- **Sleep/wake:** `protocol PowerEventSource { func observe(willSleep:, didWake:) }`.
  - `WorkspacePowerEvents` (NSWorkspace) in production, `FakePowerEvents` in tests.
  - Injected into `TartBackend.init` (`GhastApp.swift`, `TartBackend.unavailable`).
- **Role:** `enum QueueRole: String, Codable { primary, standby }`, stored as `LocalRunner.queueRole` and decoded with `decodeIfPresent ?? .primary`.

## Steps
1. **Models.** Add `QueueRole` and `JobQueueStatus`, plus `OnDemandState.queue` and `LocalRunner.queueRole` (with its coding).
   - Failing test first, in `LocalRunnerMigrationTests`: a runner saved without the key decodes as `.primary`; `.standby` round-trips.
2. **Contract change.**
   - Add `DemandRunContext`.
   - Update ScaleSet, REST, Fallback (pass-through), `FakeJobDemandSource` (`emitQueue`; records role and idleSince) and the `runDemand` call site.
   - REST reports `.noQueue` once.
   - Scale set reports `.connecting` before the session is created and `.holding` after.
   - Failing tests first: REST "reports no queue"; ScaleSet "connecting then holding".
3. **409 cadence.** `ScaleSetDemandSource.run` becomes `ensureScaleSet → loop { acquireSession (409 loop) → listen → release }`.
   - It reports `.heldElsewhere` once per streak of 409s.
   - Primary waits a fixed 10 s between tries. Standby backs off 5→10→20→40→60 s.
   - Once it gets the queue, it resets the streak and records `heldSince`.
   - Failing tests first, using FakeTransport 409s and the sleeper's requested durations.
4. **Standby yield and handoff.** `listen` checks the yield rule before each poll. On yield: DELETE the session, report `.released(.handoff)`, sleep for `handoffWindow`, then reacquire.
   - A 409 on reacquire → `.heldElsewhere`.
   - A success → `.holding`, with no immediate second yield.
   - Failing tests first, with an injected clock:
     - no yield when `idleSince` is nil
     - no yield before 5 min
     - no yield for a primary
     - yield after 5 min (DELETE, then a 30 s sleep)
     - each handoff outcome
     - the full status sequence
5. **Backend wiring.** `TartBackend` passes the context in.
   - `role` reads `host.runner(id:)?.queueRole`.
   - `onQueue` sets `entry.queue` and publishes.
   - Log transitions, skipping repeats:
     - "Took the job queue"
     - "Another Mac has the job queue; standing by"
     - "Handing the job queue back to the primary"
   - Failing tests first, in a new `TartBackendQueueTests`.
6. **Sleep and wake.** Add `Ghast/Services/Power/PowerEventSource.swift` and `FakePowerEvents`.
   - On `willSleep`, for each entry that is not shutting down:
     - mark it asleep and cancel its `demandTask`
     - call `source.close()` (fire-and-forget)
     - set `.released(.sleep)` and log "Released the job queue (sleep)"
     - leave its VMs alone
   - On `didWake`: await the old task, then restart `runDemand`. A Stop made during sleep must not be undone by the wake.
   - Failing tests first, in `TartBackendSleepTests`:
     - sleep closes the source
     - VMs are untouched
     - wake runs the source again
     - a stop while asleep stays stopped
     - REST entries stop too
7. **Display.** In `RunnerDisplayStatus`, `OnDemandPhase` gains:
   - `.standingBy` for heldElsewhere
   - `.handingOff` for released(handoff)
   - `.connecting` for connecting and released(sleep)
   - `.waitingForJobs` with a `QueueNote?` (`.thisMac`, `.noQueue`)

   VM phases take priority.
   - Detail header lines:
     - "Waiting for jobs · this Mac has the queue"
     - "Waiting for jobs · no job queue (polling GitHub)"
     - "Standing by · another Mac has the queue"
     - "Handing the queue to the primary Mac…"
   - Sidebar and menu bar show the title only.
   - `StatusDot` and `MenuBarDot` get a hollow standby style.
   - Failing tests first, in `RunnerDisplayStatusTests` and `MenuBarMenuModelTests`.
8. **Configuration tab.**
   - Add `queueRole` to `RunnerConfigurationDraft` and its save path.
   - Add a "Queue role" picker for VM runners in `RunnerConfigurationForm`, with the spec's help text.
   - The New Runner sheet defaults to Primary, with no picker.
   - Failing test first, in `RunnerConfigurationDraftTests` (the role round-trips).
9. **Snapshots.** No TDD (UI): add fixtures, record, then re-run green.
   - New states: `vmStandingBy` and `vmHoldingStandby`.
   - Re-record `vmConfiguration`.
   - Light and dark.
10. **Docs and gate.**
    - Update the CLAUDE.md bullets for VM runners.
    - Run the full suite through `heavy`, in the background.

## Accepted limitations (orchestrator decisions)
- **Hard crash or network loss on the primary:** the session lingers until GitHub expires it, which takes an unknown time. Fast failover holds only for sleep and quit.
- **Sleep:** the DELETE is fire-and-forget. If the network drops first, failover waits for the session to expire.
- **Yield timing:** the yield is checked between long polls, so it fires 5–6 min after idle starts.
- **Misconfigured pairs:** two standbys swap the queue about every 5 min, and two primaries never yield. Add a line to the help text: "Set exactly one Mac to Primary."
- **Role changes** apply live.
- **New Runner sheet:** no picker.
