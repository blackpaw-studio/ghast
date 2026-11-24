# Show the image's own resources in the Configuration tab

Status: draft, 2026-11-24

## Problem

A VM runner's Resources fields (CPU cores, memory GB, disk GB) leave a blank field at the image's value, and the placeholder only says "Image default". Users can't see what they're overriding, and the oversubscription warning skips blank fields, so a runner on an 8 GB image × 2 VMs never counts toward memory.

## Goal

Each blank Resources field shows the image's real value as its placeholder, and the warnings use those values.

## Behaviour

- **Placeholder:** a blank field shows `Image: 4`, `Image: 8`, `Image: 140` (the unit is already beside the field). While the values load, or when they can't be read, it shows `Image default` as today. A typed value is unchanged.
- **Oversubscription warning:** a blank field counts as the image's value in `VMResourcesWarning.overages`. When the image value is unknown, a blank field is skipped as today.
- **Disk note:** when the typed disk is at or below the image's disk, the field shows a grey note under it: `The image's disk is 140 GB. A disk only grows, so this has no effect.` It is advisory, not an error, and saving still works. Boot behaviour (`applyResources` skipping a non-growing disk) is unchanged.
- Values load when the Configuration tab shows a VM runner, and again when its image changes. Results are kept in memory per image ref for the session, and lookups for the same ref are shared.

## Where the values come from

`TartImageDefaults { cpuCount: Int; memoryGB: Int; diskGB: Int? }`, read by an injected `TartImageDefaultsProviding` (`func defaults(for image: String) async -> TartImageDefaults?`, never throws). In order:

1. **Local VM name** (no `/`): `tart get <name> --format json` (CPU, Memory, Disk) through the existing `TartCLI`.
2. **Pulled OCI image:** `~/.tart/cache/OCIs/<host>/<repo>/<tag>/`. `config.json` gives `cpuCount` and `memorySize` (bytes); `manifest.json`'s annotation `org.cirruslabs.tart.uncompressed-disk-size` gives the disk (bytes). Read through an injected file reader.
3. **Not pulled, ghcr.io only:** anonymous token (same flow as `GHCRXcodeVersionProvider`), `GET /v2/<repo>/manifests/<tag>` (Accept: OCI manifest), then `GET /v2/<repo>/blobs/<digest>` of the layer with mediaType `application/vnd.cirruslabs.tart.config.v1` (the manifest's `config` descriptor is the generic OCI config and has no CPU or memory). Uses the injected `HTTPTransport`. Other registries return nil.

Units: memory is bytes ÷ 1024³ (matching `tart set --memory`, which Ghast sends as GB × 1024 MB); disk is bytes ÷ 1000³, rounded down (matching `tart get`/`tart list` Disk, e.g. 140000000000 → 140). Example: `macos-tahoe-xcode:27.2` is 4 cores, 8 GB, 140 GB.

## Untrusted input

Registry and cache files are untrusted:
- HTTPS to `ghcr.io` only, plus the blob redirect target `pkg-containers.githubusercontent.com` (ghcr answers blob GETs with a 307 there); the final response URL's host must be one of the two. The repo and tag come from the saved image ref and are validated against OCI name/tag grammar before going into a URL.
- Response size caps: manifest 512 KB (Xcode image manifests are ~90 KB), Tart config layer 16 KB. The layer's SHA-256 must match the manifest's digest.
- Values must be positive and within sane bounds (CPU 1–256, memory 1–4096 GB, disk 1–100000 GB); anything else makes that value nil.
- Cache paths are built from validated components only (no `..`), and symlinks aren't followed out of `~/.tart/cache/OCIs`.

## Out of scope

- Registries other than ghcr.io for unpulled images (local cache still works for any host).
- Showing image values anywhere but the Configuration tab.
- Changing what a blank field means at boot.

## Testing

- Parsing and unit conversion from real-shaped `config.json`/`manifest.json` fixtures, including bad values and oversized input.
- Provider order (local VM → cache → registry) with a fake file reader, fake `TartCLI` and fake transport; digest mismatch and non-ghcr refs return nil.
- Draft/warning: blank field uses the image value; unknown stays skipped; disk note shows at ≤ image disk.
- Snapshots: `vmConfiguration` with image placeholders and the disk note; `vmResourcesWarning` driven partly by a blank field. Fixture uses a `FixtureImageDefaults` (no network, no `~/.tart`).
