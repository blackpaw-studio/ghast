# Tart VM resources and network isolation

Date: 2026-11-19 · Status: draft

## Goal

Let each VM runner set the CPU count, memory, disk size, and network isolation
of the VMs it boots. Today every clone inherits the image's values (Cirrus Xcode
images: ~4 cores, 8 GB), which wastes a large host like Dionysus. This lifts the
v1 non-goal "per-runner CPU/RAM/disk settings" from `2026-11-18-tart-vm-runners.md`.

## Step 0: spike on a real Cirrus clone (gates the design)

Run once on Dionysus, with VM runners stopped so the spike doesn't take a VM
slot from a live job. Record results in this spec before building.

1. `tart set <clone> --cpu 8 --memory 16384 --disk-size 150` on a clone of the
   image a runner uses. `tart get` shows the new values.
2. In the guest: `diskutil list` shows no recovery partition after the APFS
   container. `tart exec` reports which user it runs as, and `sudo -n true`
   succeeds.
3. `sudo -n diskutil repairDisk disk0` then
   `sudo -n diskutil apfs resizeContainer disk0s2 0` (both non-interactive)
   grow the container. `df -h /` shows the new size. Note how long it takes.
4. `tart run --no-graphics --net-softnet` started by a non-root user: the VM
   boots without a password prompt, `tart exec` and both `--dir` shares work,
   `curl https://github.com` succeeds, and a LAN host (`10.0.2.10`) is not
   reachable. Note what softnet setup Tart needs (setuid bit or sudoers).

If step 2 or 3 fails, the in-guest resize is dropped and disk size is handled
as described under "Disk expansion fails" below. If step 4 needs one-off host
setup, the Configuration help text documents it.

## Behaviour

**Settings** (all optional; empty means the image's value):
- CPU cores: an integer from 1 up to the host's core count.
- Memory: whole GB, from 4 up to the host's physical RAM.
- Disk size: whole GB, from 20 to 4000. Disks only grow.
- Isolate network: a toggle that adds `--net-softnet`. Off by default.

**Per-job flow**: clone → `tart set` (only the flags that are set; skipped
entirely when CPU, memory and disk are all empty) → run → wait for guest →
expand disk (only when disk size was set and actually grew) → register →
guest job. Changes apply to the next VM booted. Running VMs are left alone.

**Disk growth is checked at boot.** Read the clone's disk size from
`tart get <vm> --format json`. If the requested size is less than or equal
to the current size, leave the disk out of `tart set` and log one line
(`Disk stays at N GB: the image is already that size or larger`).

**Disk expansion fails** (non-zero exit, or an image with a recovery
partition): log one line (`Couldn't expand the disk inside the VM; the job
runs with N GB free`) and continue the job. Never fail the job for this.

**Network isolation fails closed.** If `--net-softnet` can't start (for
example, softnet isn't set up), the boot fails with Tart's error, shown in the
runner's output the same way other boot errors are. Ghast never falls back
to an unisolated VM.

**Oversubscription warning** (advisory, never blocks). The Configuration
tab shows an inline warning when any of these is over:
- CPU × 2 is more than the host's core count.
- Memory × 2 is more than the host's physical RAM.
- Disk × 2 is more than the free space on the volume that holds `~/.tart`.
  The disk files are sparse, so this is a heads-up.
The ×2 is the global 2-VM budget (`macOSVMLimit`).

**Multi-Mac**: settings live in the local `LocalRunner`, so each Mac sets its
own. Nothing is synced.

## Model and code

- New `VMResources` value type (`cpuCount`, `memoryGB`, `diskGB` as optional
  ints, `isNetworkIsolated` as a Bool) stored as `LocalRunner.vmResources`. Its
  decoding defaults to empty, so existing saved runners keep the image's values.
  `RunnerBackendKind.tart(image:)` is unchanged, so there is no enum migration.
- `TartArguments`: `set(vm:resources:)` and `run(...)` gain a softnet flag.
  `TartCLI` gains `set` and `get` (disk size).
- `TartBackend` reads `vmResources` live at each boot, like it already reads
  `backend`, and runs the disk expansion as its own `tart exec` between the
  wait for the guest and registration.
- Host capacity (core count, physical RAM, free space under `~/.tart`) comes from
  an injected `HostCapacity` protocol, backed by `ProcessInfo` and
  `URLResourceValues`.
- UI: a "Resources" group in the Configuration tab, under the image. It has
  three fields showing an "Image default" placeholder, the isolation toggle with
  one line of help, and the warning row. Saving uses the existing draft and
  debounce via a new `RunnerService.updateVMResources`. The New Runner sheet is
  unchanged: new runners start with the image's values.

## Testing

- Arguments: exact argv for `tart set` (each flag alone, all together, none →
  no call) and `tart run` with and without softnet.
- Backend, against the fake `TartCLI`:
  - Call order: clone → set → run → wait → expand → register.
  - No `set` call when the settings are empty.
  - A disk not larger than the image is skipped, with its log line.
  - A failed expansion logs and the job continues.
  - A failed softnet boot fails the boot.
- Model: an old saved runner decodes with empty `vmResources`. The settings round-trip.
- Warning logic: thresholds against a fake `HostCapacity`.
- Snapshots: the `vmConfiguration` state gets the Resources group, and there is
  a new `vmResourcesWarning` state (light and dark).

## Out of scope

Display settings, nested virtualization, extra folder mounts, MAC or serial
settings, softnet allow/block lists, Linux guests, and resource settings in the
New Runner sheet.
