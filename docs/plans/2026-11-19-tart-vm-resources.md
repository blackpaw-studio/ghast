# Plan: Tart VM resources and network isolation

Spec: `docs/specs/2026-11-19-tart-vm-resources.md` (wins on conflict). Branch `feat/tart-vm-resources`.
`T <Suite>` = `xcodebuild test -project Ghast.xcodeproj -scheme Ghast -destination platform=macOS -only-testing:GhastTests/<Suite>`. Run `xcodegen` after adding files. Commit after each step (emoji prefix, per CLAUDE.md).

## Orchestrator decisions on planner open items (2026-11-19)
- Invalid input keeps the saved value with an inline issue; blank = image default. Accepted.
- Expansion-failure line reads `Couldn't expand the disk inside the VM; the job runs on the image's N GB disk` (N = clone disk size before `set`). Spec updated to match.
- Softnet boot failure ends as `vmExitedDuringBoot` and retries with backoff in a fresh, still-isolated VM, like other boot errors. Accepted; never falls back.
- Free space read under `~/.tart`; `TART_HOME` ignored. Memory upper bound = whole GB of `physicalMemory`, rounded down. Accepted.

## Step 1: Spike on Dionysus (gates steps 3, 6, 8)
Operational, no code. Run on Dionysus as `evan` (not root). Record every output, exit code and timing in a new `## Step 0 results` section of the spec, then commit (`📝 Spec: spike results`).

Preconditions: every VM runner in Ghast on Dionysus is stopped; `tart list --format json` shows no running `ghast-*` VM and at most one running macOS VM. If a VM runner can't be stopped, stop here and report. Pick `IMAGE` from a VM runner's Configuration tab (e.g. `ghcr.io/cirruslabs/macos-tahoe-xcode:latest`).

```sh
# 1. tart set / get
tart clone "$IMAGE" ghast-spike
tart get ghast-spike --format json            # record keys + units of CPU, Memory, Disk
tart set ghast-spike --cpu 8 --memory 16384 --disk-size 150; echo "exit $?"
tart get ghast-spike --format json            # expect CPU 8, Memory 16384, Disk 150
tart set ghast-spike --disk-size 100; echo "exit $?"   # record: does shrinking error?
# 2. guest user, sudo, partition layout (start tart run with Bash run_in_background)
tart run --no-graphics ghast-spike
until tart exec ghast-spike /usr/bin/true; do sleep 2; done
tart exec ghast-spike whoami
tart exec ghast-spike sudo -n true; echo "sudo exit $?"
tart exec ghast-spike diskutil list           # record container id (disk0s2?) and any partition after it
tart exec ghast-spike df -h /
# 3. non-interactive container growth
time tart exec ghast-spike sudo -n diskutil repairDisk disk0 </dev/null; echo "exit $?"
#    if it waits for "(y/N)": time tart exec ghast-spike /bin/bash -c 'yes | sudo -n diskutil repairDisk disk0'
time tart exec ghast-spike sudo -n diskutil apfs resizeContainer disk0s2 0; echo "exit $?"
tart exec ghast-spike df -h /                 # expect ~150 GB
tart stop ghast-spike
# 4. softnet as non-root
ls -l "$(command -v softnet)" 2>&1            # record: installed? setuid root? sudoers entry?
mkdir -p "$SCRATCH/s1" "$SCRATCH/s2" && touch "$SCRATCH/s1/a" "$SCRATCH/s2/b"
tart run --no-graphics --net-softnet --dir=ghast:$SCRATCH/s1:ro --dir=ghast-job:$SCRATCH/s2:ro ghast-spike   # background
until tart exec ghast-spike /usr/bin/true; do sleep 2; done   # also record: any password prompt / sudo error in its output?
tart exec ghast-spike ls "/Volumes/My Shared Files/ghast" "/Volumes/My Shared Files/ghast-job"
tart exec ghast-spike curl -sS -o /dev/null -w '%{http_code}\n' https://github.com
tart exec ghast-spike curl -sS -m 5 http://10.0.2.10 ; echo "exit $? (expect non-zero)"
tart stop ghast-spike; tart delete ghast-spike
```

| Check | Gates | If it fails or differs |
|---|---|---|
| 1: `set` flags, memory in MB, `get` disk key (GB) | 3, 6 | Adjust argv/JSON key before writing tests. No disk field in `get` → stop and escalate. |
| 1: shrink via `--disk-size` | 6 | Nothing; the boot check already keeps smaller values out of `set`. |
| 2/3: `sudo -n` works, no recovery partition after the container, resize runs without a prompt | 6 | Use the exact working command (the `yes \|` form if needed) and the recorded container id. If the resize can't run at all, drop the `exec` from step 6 per spec (after `set` grows the disk, log the "Couldn't expand" line and continue); note it in the spec. |
| 3: resize duration | 6, Risks | Over ~60 s: flag to orchestrator (it holds a VM slot before registration). |
| 4: softnet boots non-root, shares work, internet OK, LAN blocked | 3, 8 (help text), 10 | One-off host setup (setuid/sudoers) → step 8 help line names it. LAN still reachable or no non-root setup works → stop and escalate before step 8 (the toggle would isolate nothing). |

## Steps (TDD, one commit each)

**2. `VMResources` model + persistence**
- New `Ghast/Models/VMResources.swift`: `struct VMResources: Codable, Equatable, Sendable { var cpuCount: Int?; var memoryGB: Int?; var diskGB: Int?; var isNetworkIsolated = false; static let empty; var hasSizeSettings: Bool }`, `decodeIfPresent` with defaults for every key. Bounds: `static let minMemoryGB = 4`, `diskRange = 20...4000`.
- `LocalRunner`: `var vmResources: VMResources` (init `.empty`), coding key `vmResources`, decoded `decodeIfPresent ?? .empty`, always encoded.
- Tests first, in `LocalRunnerMigrationTests`: `"a record without vmResources decodes with the image's values"` → `#expect(runner.vmResources == .empty)`; `"vm resources round-trip"` with `{cpu 8, mem 16, disk 150, isolated true}`.
- Verify: `T LocalRunnerMigrationTests`.

**3. `TartArguments` + `TartCLI.set` / disk size** (values from spike check 1)
- `TartArguments.set(_ vm: String, resources: VMResources) -> [String]?`: `["set", vm]` plus `--cpu N`, `--memory <GB×1024>`, `--disk-size N` for each set value; `nil` when none is set.
- `TartArguments.run(_:shares:isNetworkIsolated:)` puts `--net-softnet` right after `--no-graphics`.
- `TartJSON.decodeDiskSize(_:) -> Int` (spike key). `TartCLI` gains `set(_ vm:, resources:)` and `diskSizeGB(of:)`; `run` gains `isNetworkIsolated: Bool`. Update `ProcessTartCLI`.
- `FakeTartCLI`: `set` logs `set <vm> <argv tail>`; `diskSizeGB` logs `disk <vm>` and returns `diskSizeByVM[vm] ?? 50`; `run` appends ` softnet` to its log line only when isolated (existing assertions unchanged).
- Tests first, in `TartCLIParsingTests`: `"set passes only the flags that are set"` parameterised (cpu only, memory only → `16384`, disk only, all three, `.empty` → `nil`, isolation-only → `nil`); `"run adds --net-softnet only when isolated"` (exact argv both ways); `"get decodes the disk size"` from the spike's real reply.
- Verify: `T TartCLIParsingTests`.

**4. `HostCapacity` + oversubscription warning (pure logic)**
- New `Ghast/Services/Host/HostCapacity.swift`: `protocol HostCapacity: Sendable { var coreCount: Int; var physicalMemoryGB: Int; func freeDiskGB() -> Int? }`. `SystemHostCapacity` uses `ProcessInfo.processorCount`, `physicalMemory / 2^30`, and `volumeAvailableCapacityForImportantUsageKey` on `~/.tart` (falls back to `~` if missing); `nil` on error.
- `VMResourcesWarning.overages(_ r: VMResources, capacity:) -> [Overage]` (`.cpu`, `.memory`, `.disk`): `value × TartBackend.macOSVMLimit > capacity`. A `nil` value or `nil` free space never warns. Each overage has a `message`.
- Test helper `GhastTests/Mocks/FakeHostCapacity.swift`.
- Tests first, new `VMResourcesWarningTests` (16 cores / 64 GB / 300 GB free): CPU 8 → none, 9 → `[.cpu]`; memory 32 → none, 33 → `[.memory]`; disk 150 → none, 151 → `[.disk]`; empty settings and unknown free space never warn.
- Verify: `T VMResourcesWarningTests`.

**5. Backend: `set` at boot, disk growth check, softnet**
- `TartBackend.bootAndRun` reads `runner.vmResources` (from the runner `reconcile` reads live per `launchVM`). After `clone`: if `diskGB` is set, `current = cli.diskSizeGB(of:)`; when `diskGB <= current`, drop disk and log `Disk stays at \(current) GB: the image is already that size or larger`. If anything remains, `cli.set`; record `vm.diskGrewTo` when the disk grows. Pass `isNetworkIsolated` to `cli.run`.
- Fake: `runExitCode: Int32?` makes `run` call `onExit` at once (softnet failure).
- Tests first, new `TartBackendResourcesTests` (reuse `TartHarness`):
  - `"with settings the call order is clone, disk, set, run, probe, register"`.
  - `"empty settings never call set or read the disk"`.
  - `"a disk not larger than the image is left out of set and logged"`: image 50, ask 50 → `set` has `--cpu` but no `--disk-size`, exact log line; disk-only 40 → no `set`.
  - `"settings changed between VMs apply to the next VM only"`: cpu 4 then 8.
  - `"isolation boots with softnet"`.
  - `"a softnet boot that fails fails the boot and never falls back"`: `runExitCode = 1` → `vmExitedDuringBoot`, no `jitConfig`, clone deleted; the retried `run` still has ` softnet`, never a `run` without it.
- Verify: `T TartBackendResourcesTests`, `T TartBackendTests`.

**6. Backend: in-guest disk expansion** (command from spike checks 2–3)
- `TartGuestScript.expandDisk: [String]` (e.g. `["/bin/bash","-c","<spike command>"]`).
- In `bootAndRun`, after `waitForGuest`/`isReachable`, when `vm.diskGrewTo` is set: `cli.exec(vm.clone, TartGuestScript.expandDisk)`. Non-zero exit or throw → log `Couldn't expand the disk inside the VM; the job runs on the image's \(n) GB disk` and continue. Then `checkStop`.
- Fake: `expandExitCode: Int32 = 0`, returned by `exec` for the expand argv.
- Tests first, in `TartBackendResourcesTests`: order test extended to `clone → disk → set → run → probe → exec <expand> → jit`; `"no expansion when the disk did not grow"`; `"a failed expansion logs one line and the job still runs"` (`expandExitCode = 1` → exact line, `exec-stream` still happens, no failure counted).
- Verify: `T TartBackendResourcesTests`.

**7. `RunnerService.updateVMResources` + draft**
- `RunnerService.updateVMResources(id:resources:)`: guards `.tart`, then `updateRunner`.
- `RunnerConfigurationDraft`: init gains `hostCapacity: any HostCapacity`; fields `vmCPU`, `vmMemory`, `vmDisk` (text) and `vmIsolated`, loaded from `runner.vmResources` (blank when `nil`). `static func parseResource(_ text:, range:) -> ResourceInput { .blank, .value(Int), .invalid }`. Ranges: CPU `1...capacity.coreCount`, memory `4...capacity.physicalMemoryGB`, disk `20...4000`. `resourceIssue(for:)` for inline messages; `overages` computed from typed valid values.
- `saveSoon` tart branch: blank → `nil`, invalid → keep saved value, valid → value; call `updateVMResources` only on change; `needsRestart` stays false.
- Tests first, in `RunnerConfigurationDraftTests`: `vmResourcesLoadAndSaveWithoutAskingForARestart`; `blankResourceFieldsSaveAsImageDefault`; `outOfRangeOrNonNumericResourceKeepsTheSavedValue` (cpu `"99"` on 16 cores, memory `"2"`, disk `"abc"` → unchanged, each with an issue); `typedResourcesDriveTheWarning` (cpu `"12"` → `[.cpu]`).
- Verify: `T RunnerConfigurationDraftTests`.

**8. UI: Resources group** (no TDD: UI styling; covered by snapshots in step 9)
- `RunnerFlowServices` gains `var hostCapacity: any HostCapacity = SystemHostCapacity()`; `RunnerDetailViews` passes it to `RunnerConfigurationForm`, whose init forwards it to the draft.
- In `RunnerConfigurationForm.virtualMachineSection`, a "Resources" group under the image: three `vmField`s (CPU cores, Memory (GB), Disk (GB)) with prompt `"Image default"`; issue text under each, styled like the env-var issue; toggle "Isolate network" with one `secondaryText` help line (blocks the local network, keeps internet; plus any host setup from spike check 4); a warning row (`exclamationmark.triangle`, `FocusColor` warning token) listing each overage, shown only when non-empty.
- Edits call `draft.saveSoon()`, commit calls `flush`, like existing fields.
- Verify: `xcodebuild build -project Ghast.xcodeproj -scheme Ghast`.

**9. Snapshots + fixture**
- Fixture (`Ghast/Fixture/FixtureDependencies.swift`) and the snapshot environment inject `FakeHostCapacity(16 cores, 64 GB, 300 GB)` so renders never read the host.
- `FocusMainSnapshotTests`: `vmConfiguration` runner gets `{8, 16, 150, isolated true}`; new state `vmResourcesWarning` with `{12, 48, 200}` (all three warn), added to `isVM` and the `.configuration` tab mapping.
- Record with `TEST_RUNNER_SNAPSHOT_RECORD_MODE=true xcodebuild test -project Ghast.xcodeproj -scheme Ghast -only-testing:GhastTests/FocusMainSnapshotTests`, re-run without it to confirm green, inspect the new PNGs at native size, commit `GhastTests/__Snapshots__/` (light and dark).
- Verify: `T FocusMainSnapshotTests`, `T FixtureSafetyTests`.

**10. Docs**
- `CLAUDE.md` Runner Management VM bullet: per-runner `vmResources` (CPU, memory GB, disk GB, isolate network) read live at each boot; `tart set` after clone; disk grow-only (checked with `tart get`) and expanded in the guest, failure logged and never fatal; `--net-softnet` fails closed; advisory ×2 oversubscription warning via injected `HostCapacity`; any softnet host setup from the spike. Add `vmResourcesWarning` to the snapshot state list.

## Integration gate
1. Background: `heavy xcodebuild test -project Ghast.xcodeproj -scheme Ghast -destination platform=macOS`.
2. `review` on `git diff main...HEAD`. Bar: P0/P1 plus anything a real VM boot, Stop mid-boot/expansion, or a saved-runner upgrade can hit.
3. Live on Dionysus with a VM runner at CPU 8, memory 16, disk 150, isolation on: queue a job; the log shows `set`, boot, expansion, job. In-job step: `sysctl -n hw.ncpu`, `sysctl -n hw.memsize`, `df -h /` match; `curl -m 5 http://10.0.2.10` fails; checkout works. Clone deleted after the job. Then disk 20 → "Disk stays at…" line. Then clear all fields → no `set` call.

## Risks
- Resize depends on the image layout. A Cirrus update that adds a recovery partition turns every grown disk into the log line (not fatal); the spike records today's layout.
- Expansion holds a VM slot before registration. A slow resize delays the job, and Stop during it waits for `tart exec` to return (`ProcessRun` may not be cancellable). Spike timing decides whether this matters.
- Softnet setuid/sudo setup is host-wide and outside Ghast; without it every isolated boot fails and retries with backoff indefinitely.
- Oversubscription is advisory only; two max-sized VMs can starve the host (accepted by spec).
- Disk files are sparse: the disk warning can fire while there's room, and real use can still fill the volume.
