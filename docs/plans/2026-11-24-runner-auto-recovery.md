# Plan: runners recover on their own

Spec: `docs/specs/2026-11-24-runner-auto-recovery.md` (source of truth). Branch `feat/runner-auto-recovery`.
Every test command takes `PRODUCT_BUNDLE_IDENTIFIER=net.evancoleman.ghast.testhost` (needed while the installed Ghast runs):
`xcodebuild test -project Ghast.xcodeproj -scheme Ghast -only-testing:GhastTests/<Suite> PRODUCT_BUNDLE_IDENTIFIER=net.evancoleman.ghast.testhost`
Run `xcodegen` after adding files. Commit after each step (emoji prefix, per CLAUDE.md).

## Design (fixed)
- `RecoveryPolicy` (new `Ghast/Services/Recovery/RecoveryPolicy.swift`, value type): `delays: [Duration] = [.seconds(5), .seconds(30), .seconds(120)]`, `healthyWindow: Duration = .seconds(600)`, `maxAttempts = delays.count`, `static let standard`. It has one pure function: `decide(attemptsSoFar: Int, exit: RunnerExit) -> RecoveryDecision`, which returns `.retry(attempt: Int, after: Duration)` or `.giveUp(attempts: Int)`. The healthy-run reset is decided from the exit: if `exit.startedAt != nil` and `exit.at - startedAt >= healthyWindow`, the count is treated as 0. That needs no timer, and a failed start (no `startedAt`) never resets.
- `RetryWait` (Sendable, Equatable): `attempt`, `maxAttempts`, `dueAt: Date`, `lastExit: RunnerExit`. New state `RunnerProcessState.waitingToRetry(RetryWait)`.
- `RunnerRecovery` (new `@MainActor final class`, `Ghast/Services/Recovery/RunnerRecovery.swift`) is owned by `RunnerService`. It holds attempts per id, one pending timer `Task` per id and the `RetryWait`. It takes the policy, clock, sleeper and `PowerEventSource`. API: `schedule`, `cancel(id)`, `cancelAll()`, `resetAttempts(id)`, `takePending(id)`. On `didWake`, it fires every pending wait whose `dueAt <= clock.now()` immediately.
- Injection: `RunnerService.init` gains `recoveryPolicy: RecoveryPolicy = .standard`, `recoverySleeper: Sleeper? = nil` (nil means the service's `sleeper`) and `power: any PowerEventSource = NoPowerEvents()`. `AppDependencies.live` passes `.standard` and one shared `WorkspacePowerEvents()` instance to both `RunnerService` and `TartBackend` (`observe` can be called more than once). `FixtureDependencies` keeps the defaults.

## Steps

### 1. RecoveryPolicy decision (pure)
- Files: `RecoveryPolicy.swift` and a new `GhastTests/RecoveryPolicyTests.swift`.
- Failing tests first:
  - Delays come back 5 s → 30 s → 120 s for attempts 1, 2, 3.
  - The fourth decision is `.giveUp(3)`.
  - An exit after a run of at least 600 s restarts the count at attempt 1.
  - An exit after 599 s doesn't.
  - A start failure (`startedAt == nil`) continues the count.
- Verify: `-only-testing:GhastTests/RecoveryPolicyTests`.

### 2. Intent survives; retries are scheduled (RunnerService + RunnerRecovery)
- Files:
  - `RunnerProcessState.swift`: add `.waitingToRetry(RetryWait)`; `restored(from:)` is unchanged.
  - `RunnerRecovery.swift`.
  - `RunnerService.swift`:
    - Delete `:211` (`shouldBeRunning = false`).
    - In `recordExit` (`:194`), when `!wasRequested && runner.shouldBeRunning`, ask the policy:
      - On `.retry`, persist `lastExit`, set `.waitingToRetry`, schedule, and yield nothing.
      - On `.giveUp`, set `.exited`, keep the intent, and always yield, including after a start failure (`announces: false`), with `gaveUpAfter: n` (step 5).
      - Otherwise, behave as today.
    - Fix the doc comments at `:192`, `TartBackend.fail` and `:185`.
  - The retry timer calls the backend's `start(id:)` directly, not the public `startRunner` (which would reset the count), and calls `recordStartFailure` on a throw. Before starting it checks that the runner exists, still has `shouldBeRunning`, and is still in the same `RetryWait`.
- Failing tests (new `GhastTests/RunnerRecoveryTests.swift`, `ManualSleeper` + `FakeClock` + `ControllableLauncher`/`FakeLauncher`):
  - An unexpected exit keeps `shouldBeRunning` and shows `.waitingToRetry(attempt 1, dueAt now+5 s)`.
  - Waking the sleeper launches again.
  - Three failed retries end in `.exited` with the intent still set.
  - An exit after a run of at least 600 s goes back to attempt 1.
  - `recordStartFailure` keeps the intent and schedules a retry.
- Update `RestartAtLaunchTests.recordedFailureIsError` (`:146`, `:161`): the intent stays true and the state is `.waitingToRetry`. Rename the test to match.
- Test-host safety: `makeTestRunnerService` (`GhastTests/Support/TestDefaults.swift`) and every direct `RunnerService(` in tests that can see an unexpected exit pass a parked `recoverySleeper` (one that never returns), so no real 5 s timer launches anything. Audit with `grep -rn "RunnerService(" GhastTests`.
  - Existing assertions on `.exited`/intent cleared after an unexpected exit change to the new behaviour, at minimum in `RunnerWrapperTests` and `TartBackend*Tests`. Each changed assertion gets a one-line note in the commit.
- Verify: `RunnerRecoveryTests`, `RestartAtLaunchTests`, `RunnerShutdownTests`, `RunnerProcessLifecycleTests`, `RunnerWrapperTests` (`-only-testing` takes several).

### 3. Start, Stop, Remove
- Files:
  - `RunnerService.startRunner`: if the runner is waiting, take the pending wait and run that attempt now (the count is kept). Otherwise reset the attempts. Then set `shouldBeRunning = true` before calling the backend, so a failed user start keeps its intent.
  - `stopRunner`: cancel and reset; if the runner was waiting, set `.stopped` (no backend has a process to settle it).
  - `removeLocalRunner` / `removeAllLocalRunners`: cancel.
  - `Views/Focus/RunnerActions.swift`: in `start`/`restart`, call `runnerService.recordStartFailure(id:)` in the `catch` (today they only log).
- Failing tests (`RunnerRecoveryTests`):
  - Start on a waiting runner launches at once, without waking the sleeper, and keeps the attempt number.
  - A later sleeper wake doesn't start it a second time.
  - Stop on a waiting runner clears the intent, shows `.stopped`, and nothing launches after the sleeper wakes.
  - A failed user start through `RunnerActions` schedules a retry.
  - Stop during a pending start never schedules one (the intent is cleared, so `recordExit` falls through).
- Verify: `RunnerRecoveryTests`, `ConcurrentRunnerOperationsTests`, `RestartAtLaunchTests`.

### 4. Quit and wake
- Files:
  - `RunnerService`: add `cancelPendingRestarts()`, which cancels all and keeps the intent; `stopAllRunners()` calls it first.
  - `GhastApp.swift` `applicationShouldTerminate` (`~560`): call `runnerService.cancelPendingRestarts()` before the `stopsRunnersOnQuit` guard. That one line of glue gets no test.
  - `RunnerRecovery`: register `power.observe(didWake:)`.
- Failing tests (`RunnerRecoveryTests`, `FakePowerEvents`):
  - `stopAllRunners` and `cancelPendingRestarts` keep `shouldBeRunning` and launch nothing after the sleeper wakes.
  - With the sleeper parked and the clock moved past `dueAt`, `power.wake()` launches.
  - A wake before `dueAt` launches nothing.
- Verify: `RunnerRecoveryTests`, `RunnerShutdownTests`.

### 5. Notifications
- Files:
  - `NotificationPolicy.swift`: add `RunnerProcessExit.gaveUpAfter: Int?` (default nil).
  - In `NotificationPolicy.notice`, a give-up returns kind `.unexpectedStop`, gated on the same `notifyUnexpectedStop` setting and not filtered by `selfUpdateExitCodes`. Title: `<runner> stopped after 3 restart attempts`. Body:
    - `The runner exited with code N. Click to see its output.`
    - For `RunnerExit.launchFailureCode`: `Ghast couldn't start it. Click to see its output.`
- Failing tests:
  - `NotificationPolicyTests`: a give-up gives one notice with that title, honours the toggle, and uses the start-failure wording.
  - `RunnerRecoveryTests`: draining `processExits` shows no event for a retried exit and exactly one, with `gaveUpAfter == 3`, after the third failed retry.
- Verify: `NotificationPolicyTests`, `RunnerRecoveryTests`.

### 6. VM runners and ConnectionWatch
- Files:
  - `TartBackend.finish` (`~831`) already reports a demand-loop failure as `recordExit(wasRequested: false)`, and a job VM failing never reaches it. Leave the code and confirm it with a test.
  - `Services/Provisioning/ConnectionWatch.swift:81`: treat `.waitingToRetry(wait)` as `.failure(.exited(wait.lastExit.code))`.
- Failing tests:
  - `TartBackendTests` (RunnerService with a fake demand source that throws): after the loop fails, the state is `.waitingToRetry` and the intent is kept.
  - A job VM failure leaves the runner `.onDemand`.
  - `ReconfigureTests` or `RunnerSetupFlowTests`: an exit during the watch reports a failure.
- Verify: `TartBackendTests`, `TartBackendOnDemandTests`, `ReconfigureTests`, `RunnerSetupFlowTests`.

### 7. Visible waiting state (words)
- Files:
  - `Models/RunnerDisplayStatus.swift`:
    - Add `case restarting(RetryWait)`; `make` maps `.waitingToRetry` to it.
    - Title text `Restarting in 30 s (attempt 2 of 3)`. Remaining time is rounded up: "N s" under 60, "N min" otherwise; at or below 0 it reads `Restarting… (attempt 2 of 3)`. The title and `sidebarSubtitle` take a `DisplayTime`; thread it from the callers (`RunnerStatusHeader:18`, `RunnerSidebar:122`).
    - `secondaryLine` is the error's line (`Stopped unexpectedly at …`).
    - `toolbarButtons`: `[.start enabled, .stop enabled]`.
    - `showsProgress` is false. The dot matches `.error`. Add the spoken text. `localStats` reads Last Run.
  - `MenuBarMenuModel.swift`:
    - The badge is the same text and `isRunning` is false.
    - The submenu is `[.showOutput, .separator, .start, .stop]`.
    - `make` takes `now`; `AppDependencies.makeMenuBarController` passes `clock.now()`.
  - Sidebar refresh: wrap the row's subtitle in the same `TimelineView(.periodic … headerRefreshInterval)` the detail uses (`RunnerDetailViews:18`).
- Failing tests:
  - `RunnerDisplayStatusTests`: the title, sidebar text, rounding, button set, and dot or `showsProgress`.
  - `MenuBarMenuModelTests`: the badge and submenu.
  - `RunnerCatalogTests`, if the mapping is covered there.
- Verify: `RunnerDisplayStatusTests`, `MenuBarMenuModelTests`, `RunnerCatalogTests`.

### 8. Snapshots (record, then confirm)
- `FocusMainSnapshotTests`: add `State.restarting`. The error runner shows `.waitingToRetry(RetryWait(attempt: 2, maxAttempts: 3, dueAt: fixtureNow + 30 s, lastExit: <fixture exit>))`.
- Add a `sidebarRestarting` test (light and dark) that renders `RunnerSidebar` at `FocusMetrics.sidebarColumnWidth` with that runner waiting. No sidebar snapshot exists today.
- Record: `TEST_RUNNER_SNAPSHOT_RECORD_MODE=true xcodebuild test … -only-testing:GhastTests/FocusMainSnapshotTests PRODUCT_BUNDLE_IDENTIFIER=net.evancoleman.ghast.testhost`. Run it again without the variable to confirm green. Check the new PNGs at native pixels; existing PNGs must not change.
- Commit the PNGs in `GhastTests/__Snapshots__/`.

### 9. Docs, then hand off
- `CLAUDE.md` Runner Management: add one bullet on recovery (the intent rules, `RecoveryPolicy`, the waiting state, the give-up notification). Add `restarting` to the FocusMainSnapshotTests state list.
- Stop here. The orchestrator runs the full suite (`heavy`, in the background) and the fresh-context review. Don't run either in this branch's implement rounds.

## Risks / open questions
1. **Intent is set before the start (step 3).** `startRunner` now persists `shouldBeRunning = true` before the backend launches. Flow starts (New Runner, Reconfigure) inherit this, so a flow's failed start keeps the intent but doesn't retry, because flows don't call `recordStartFailure`. The next launch then restarts that runner. That's consistent with "only the user turns a runner off", but it's a change.
2. **Existing test churn.** Tests asserting `.exited` or a cleared intent after an unexpected exit change meaning, and every one changed must be listed. Real-process tests (`RunnerWrapperTests`) must use the parked recovery sleeper, or a retry could launch a wrapper later in the suite.
3. **Give-up reason for VM runners.** A VM give-up shows only "couldn't start" (`launchFailureCode`); the demand loop's error text is only in the log. Carrying the message would need a `RunnerExit` change, which the spec doesn't ask for.
4. **Self-update exit codes.** An unrequested wrapper exit with code 0 or 2 now retries (today it is silently `.exited`). The give-up notice deliberately ignores `selfUpdateExitCodes`.
5. **Menu bar badge width.** The full `Restarting in 2 min (attempt 3 of 3)` text in the menu bar badge may be wide. The spec asks for the same text everywhere, so check it in the capture.

## Orchestrator decisions
- Risks 1, 2 and 4 accepted as written (intent set before start; churned assertions listed in commits; unrequested exits with code 0/2 retry, then give up).
- Risk 3: no `RunnerExit` change; the VM give-up wording stays generic.
- Risk 5: if the menu bar badge is too wide in the capture, use `Restarting in 30 s` there (drop the attempt count in the badge only).
