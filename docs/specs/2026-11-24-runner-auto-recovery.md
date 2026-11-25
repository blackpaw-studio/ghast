# Runners recover on their own

Status: approved in direction by Evan ("go with your recs"), 2026-11-24. Closes #38 and #13.

## Problem

Ghast keeps a runner's run intent (`LocalRunner.shouldBeRunning`) across quit, update and reboot, and `RestartAtLaunch` starts those runners again. But two paths clear the intent:
- `recordExit(wasRequested: false)` clears it after any unexpected exit (`RunnerService.swift:211`);
- `recordStartFailure` clears it when a start fails, including the restart at launch (asserted on purpose in `RestartAtLaunchTests`).

A runner that crashes once, or can't start once at launch, stays down after every later relaunch until someone clicks Start. Nothing retries in the meantime. That is the likely cause of the overnight outage in #38.

## Behaviour

1. **Only the user turns a runner off.** Stop, Stop All and Remove clear the run intent. An unexpected exit or a failed start keeps it.
2. **Retry with backoff.** After an unexpected exit or a failed start (a user start, the launch restart, or a retry), Ghast starts the runner again after 5 s, then 30 s, then 2 min. After the third failed retry it gives up: the runner shows its error (`.exited`) as today. Its intent stays set, so the next launch tries again.
3. **A healthy run resets the count.** A run that stays up for 10 minutes resets the attempt count to zero.
4. **Waiting is visible.** While waiting to retry, the runner shows `Restarting in 30 s (attempt 2 of 3)` wherever it shows its state today (sidebar row, detail header, menu bar). Start on a waiting runner retries now. Stop cancels the retry and clears the intent.
5. **Notifications.** An exit that will be retried posts no notification. Giving up posts one: `<runner> stopped after 3 restart attempts`, with the last exit's reason. That goes through the existing `NotificationService` and its user setting.
6. **Quit and sleep.** Quit cancels pending retries and keeps the intent, so the launch restart handles the runner. A retry that comes due while the Mac sleeps runs on wake.
7. **Both kinds of runner.** For a host runner, the trigger is the process exit. For a VM runner, it is the demand loop ending with an error (`.exited`), not a job VM failing. A job VM failing is already handled per job.

All timings live in one injected `RecoveryPolicy` (delays `[5, 30, 120]` s, healthy window 600 s). Tests use a fake clock and sleeper.

## Out of scope

- The rest of #13's wishlist: resource graphs, a health dashboard, exported reports, per-runner settings for restart limits, and a health line in the detail view.
- Detecting a runner that is running but stuck.
- Telling a permanent failure from a transient one (for example a runner deleted on GitHub). Three retries, then giving up, covers it.

## Testing

- Intent survives an unexpected exit and a failed start. Stop clears it. Update the existing `RestartAtLaunchTests` case that asserts the old behaviour.
- The backoff sequence and giving up after three retries; the reset after a healthy run; Start skipping the wait; Stop cancelling a pending retry; quit cancelling retries.
- Notifications: none for a retried exit, one when Ghast gives up.
- A snapshot for the `Restarting in …` state (sidebar and detail).
