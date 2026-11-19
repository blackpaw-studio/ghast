# Multi-host VM runners: queue lease, sleep release, standby

## Problem
Two Macs can run a VM runner with the same name (same org, same group). They share one scale set, but GitHub lets only one message session (the **job queue**) exist per scale set. Today:
- The first Mac to connect keeps the queue.
- The other Mac retries a 409 forever.
- A sleeping Mac keeps the queue, so jobs stall.
- Nothing in the UI says which Mac has the queue.

## Goal
Example setup: the laptop is the primary and Dionysus is the standby.
- **Priority:** the primary gets jobs whenever it is awake.
- **Failover:** the standby takes over within about a minute when the primary sleeps, quits or disappears.
- **Visibility:** each Mac's UI says plainly whether it holds the queue.

## Behaviour
1. **Release on sleep:**
   - On `NSWorkspace.willSleepNotification`, every on-demand runner deletes its message session and stops polling.
   - On `didWakeNotification`, it reopens the session.
   - Running VMs are left alone, since they freeze with the host anyway.
   - Sleep is not blocked.
2. **Queue role** (a per-runner setting for VM runners): **Primary** (the default) or **Standby**.
   - **Primary:** on a 409, it retries every 10 s (fixed, no growing backoff).
   - **Standby:** on a 409, it retries with the existing backoff, capped at 60 s.
   - **Standby yield:** when the standby holds the queue and has been idle for 5 min (demand 0, no VMs), it deletes its session. It then waits a 30 s handoff window before trying again. A live primary takes the queue in that window. If the primary is gone, the standby takes the queue back.
   - The standby never yields while a VM is running or demand is > 0.
   - Constants are named and injected, tested with an injected clock.
3. **REST fallback** (no session): unchanged. The role and queue status do not apply, and the UI says so. This is a known limitation: two hosts in REST fallback can both boot a VM for one job, as they do today.

## UI
- **Queue status** comes from a new field on the on-demand state:
  - `holding`: "This Mac has the job queue"
  - `heldElsewhere`: "Another Mac has the job queue · standing by"
  - `connecting`
  - `released`: asleep or handing off; shown as "Handing the queue to the primary Mac…" during a standby yield
- **Detail header:** status line, e.g. "Waiting for jobs · this Mac has the queue" / "Standing by · another Mac has the queue".
- **Sidebar and menu bar:** status text. A standing-by runner gets a distinct dot style (hollow/secondary), so it isn't mistaken for idle-and-ready.
- **Configuration tab:** a "Queue role" picker (Primary / Standby), with a one-line help text: "Use Standby on an always-on Mac that should take jobs only when your primary Mac is asleep or off."
  - New Runner sheet: VM runners default to Primary.
- **Log lines** on each transition: "Took the job queue", "Another Mac has the job queue; standing by", "Released the job queue (sleep)", "Handing the job queue back to the primary".
- **Snapshots:** new detail states `vmStandingBy` and `vmHoldingStandby`, plus the configuration tab with the role picker.

## Out of scope
- Overflow to the other Mac when the queue holder is full.
- Per-host runner names and routing.
- Showing which other Mac holds the queue: the 409 doesn't say.

## Tests
Unit tests with fake transport, clock and sleeper:
- primary 409 cadence vs. standby 409 cadence
- the standby yields only when idle for the interval
- handoff window then reclaim
- sleep deletes the session
- wake reopens it
- queue status transitions
- REST fallback reports no queue status
