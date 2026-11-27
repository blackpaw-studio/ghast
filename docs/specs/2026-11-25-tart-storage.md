# Tart Storage: see and free the disk Tart uses

Status: draft, 2026-11-25. Option A (show and clean by hand) chosen by Evan; local VMs: listed, removable, never bulk-removed.

## Problem

Tart images are huge (Xcode images unpack to ~140 GB) and Ghast never shows or removes them. Dionysus reached 3.9 GB free. When the disk is full, `tart pull` fails, Ghast treats the failure as transient and retries until it gives up, and the log never says "out of space".

## Behaviour

### Tart Storage section (Settings › General, after Cache)

- Header line: `Tart uses 412 GB · 88 GB free on this disk`.
- One row per image, sorted by size: name (short ref, e.g. `macos-tahoe-xcode:26.3`), size, last used (`Accessed`, relative: "3 days ago"), and a usage line: `Used by blackpaw-macos-tahoe-xcode-26-3` (runner names), or `Not used by any runner`.
  - A pulled image's tag row and digest row (`…@sha256:…`) are one image. Its size is counted once.
  - Local VMs (`Source: local`) are listed in their own group, labelled `Local VMs`. Ghast's own clones (`ghast-*`) are not listed.
- **Remove** (per row, behind a confirmation naming the image and the space it frees):
  - Disabled with the reason as help text when a runner uses the image, or while it is being pulled.
  - For a pulled image it runs `tart delete` on the **digest** ref (deleting a tag only removes its symlink; Tart's gc then drops the dangling tag links). For a local VM, the confirmation adds `This VM was made on this Mac and can't be downloaded again.`
- **Remove Unused** (behind a confirmation listing the images and the total freed): removes every pulled image no runner uses. Never removes local VMs. Disabled when there is nothing to remove.
- The list refreshes when the section appears, after a remove, and when a pull finishes. A failed remove shows its error inline and keeps the row.

### Free-space check before a pull

- Before `tart pull`, Ghast estimates the space the image needs (the image's disk size from the same lookup as the image defaults: Tart cache, then ghcr.io) and compares it with free space on `~/.tart`'s volume (`HostCapacity`).
- The estimate is the image's `Disk` (manifest `uncompressed-disk-size`) + 128 MiB, the same reservation Tart itself checks before a pull (it overstates real use by ~35% because `disk.img` is sparse, but it is what Tart enforces). If it doesn't fit, the runner stops with an error and does **not** retry: `Not enough disk space to pull macos-tahoe-xcode:26.3: needs about 140 GB, 88 GB free. Free space in Settings › General › Tart Storage.` Its run intent is kept, so Start (or the next launch) tries again.
- If the size is unknown, the pull runs as today.
- Clones are not checked (APFS clones share blocks).
- Ghast runs `tart pull` with `TART_NO_AUTO_PRUNE=1`. Without it, a pull short of space makes Tart silently delete cached images (possibly one another runner uses) to make room. Freeing space stays the user's call, in Tart Storage.

## Step 0 results (2026-11-25, Dionysus, Tart 2.42.0, read-only)

- Tags (`latest`, `26.3`, …) are symlinks to digest folders under `~/.tart/cache/OCIs/<host>/<repo>/`. All bytes live in the digest folders; `du ~/.tart` equals their sum. Summing `tart list` `Size` over tag and digest rows double counts (596 vs ~290 GB).
- `tart list` `Size` = allocated bytes (config + disk + nvram), floored to decimal GB; matches `du`. `Disk` = logical disk size = manifest uncompressed size. Real use is 59–72% of `Disk` (sparse `disk.img`).
- `tart delete <tag>` removes the symlink only; explicitly pulled digests are never garbage-collected. `tart delete <digest>` removes the folder and gc drops dangling tags (`VMStorageOCI.swift:222-262`).
- Pull writes into `~/.tart/tmp`, `disk.img` pre-truncated and streamed with zero-skipping; no separate compressed copy. Before pulling Tart requires uncompressed + 128 MiB and otherwise calls `Prune.reclaimIfNeeded`, which deletes cached images unless `TART_NO_AUTO_PRUNE` is set (`VMStorageOCI.swift:478-484`, `Prune.swift:114-152`).
- Row size and header total use `Size` of digest rows (each image once). Dionysus: 4 images, ~290 GB, 25 GiB free.

## Out of scope

- Automatic pruning or a space budget (option B). Tart's own auto-prune on pull is left as is.
- IPSW caches and `tart prune` controls.
- Showing storage anywhere but Settings.

## Testing

- Grouping tag and digest rows; sizes counted once; `ghast-*` hidden; local VMs grouped.
- In-use detection from runners' `.tart(image:)` (both tag and digest refs); Remove disabled when used or pulling; Remove Unused skips used images and local VMs.
- Free-space check: blocks with the message when it won't fit, passes when it fits, skips when size unknown; a blocked pull doesn't retry and keeps the intent.
- Fake `TartCLI`, `HostCapacity` and image-size source; no real Tart or disk.
- Snapshot: Settings › General with Tart Storage (pulled images, a local VM, one in use).
