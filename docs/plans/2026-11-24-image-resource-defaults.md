# Image resource defaults — implementation plan

Spec: `docs/specs/2026-11-24-image-resource-defaults.md` (it wins any conflict). Branch `feat/image-resource-defaults`.
Test command used below: `xcodegen && xcodebuild test -project Ghast.xcodeproj -scheme Ghast -only-testing:GhastTests/<Suite>` (run `xcodegen` again after adding files).

## 0. Spec corrections (applied to the spec)
Checked against ghcr.io and `~/.tart` for `macos-tahoe-xcode:27.2`:
- **Manifest cap:** the real manifest is 91,607 B, over the spec's 64 KB. Proposed cap: **512 KB**. The 16 KB config cap stays.
- **Where CPU and memory live:** the manifest's `config` descriptor is the OCI image config (`architecture`, `os`, `Labels` only). `cpuCount` and `memorySize` are in the layer with mediaType `application/vnd.cirruslabs.tart.config.v1`. Fetch that layer's digest. Its SHA-256 check and 16 KB cap apply as written.
- **Blob redirect:** `GET /v2/<repo>/blobs/<digest>` returns 307 to `https://pkg-containers.githubusercontent.com/...`. Proposal: allow redirects only to that HTTPS host, and check `response.url` against the two allowed hosts. The SHA-256 check still protects integrity.

## 1. Image refs and parsing: models only
New `Ghast/Services/Tart/TartImageDefaults.swift`:
- `struct TartImageDefaults: Equatable, Sendable { cpuCount: Int; memoryGB: Int; diskGB: Int? }`.
- `TartImageDefaults.Bounds`: CPU 1–256, memory 1–4096, disk 1–100000.
- Validators that return nil when a value is out of bounds.
- If CPU or memory is invalid, the whole result is nil, because the spec types both as non-optional. If only the disk is invalid, `diskGB` is nil.

New `TartImageRef.swift`:
- `TartImageRef.parse(_:) -> TartImageRef?`, giving `host`, `repository`, `tag`.
- Repository path components follow `[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*`.
- Tags follow `[A-Za-z0-9_][A-Za-z0-9._-]{0,127}`.
- The host follows domain grammar with an optional port.
- A missing tag means `latest`, as in Tart.
- Anything with `..`, an empty component, or no `/` returns nil.

New `TartImageConfigParser` (enum):
- `vmConfig(Data) -> (cpu: Int?, memoryGB: Int?)`: `cpuCount`, and `memorySize` bytes ÷ 1024³.
- `manifest(Data) -> TartManifestInfo { vmConfigDigest, vmConfigSize, diskGB? }`: the `vnd.cirruslabs.tart.config.v1` layer, and the annotation `org.cirruslabs.tart.uncompressed-disk-size` ÷ 1000³, rounded down.
- `TartJSON.decodeInfo(Data) -> TartVMInfo { cpu, memoryMB, diskGB? }` reads `CPU`, `Memory` (MB) and `Disk`. Memory in GB is MB ÷ 1024.

Failing tests first, in `GhastTests/TartImageDefaultsParsingTests.swift`:
- Use real-shaped fixtures in `GhastTests/Fixtures/` (trimmed copies of the 27.2 manifest and config layer).
- Check the units: 8589934592 → 8; 140000000000 → 140; 139999999999 → 139.
- Bad values return nil: 0, negative, 257 CPUs, a non-numeric annotation, missing keys.
- Ref grammar cases: `..`, uppercase repo, a 129-character tag, a bare name, a digest ref.

Add `decodeInfo` cases to `TartCLIParsingTests`.

Verify: `-only-testing:GhastTests/TartImageDefaultsParsingTests -only-testing:GhastTests/TartCLIParsingTests`.

## 2. `TartCLI.info(of:)`
Add `func info(of vm: String) async throws -> TartVMInfo` to `TartCLI` (`Ghast/Services/Tart/TartCLI.swift`). `ProcessTartCLI` implements it with `TartArguments.get` and `TartJSON.decodeInfo`. Update `GhastTests/Mocks/FakeTartCLI.swift` and any other conformers (`grep -rn ": TartCLI"`).
Failing test: a `ProcessTartCLITests` case where a scripted `tart get` output decodes to `TartVMInfo`.
Verify: `-only-testing:GhastTests/ProcessTartCLITests`.

## 3. Provider: local VM → cache → ghcr
New `Ghast/Services/Tart/TartImageDefaultsProvider.swift`:
- `protocol TartImageDefaultsProviding: Sendable { func defaults(for image: String) async -> TartImageDefaults? }`.
- `struct TartImageDefaultsProvider` with injected `cli: @Sendable () async throws -> any TartCLI` (production: `TartBackend.systemCLIProvider()`), `cache: any ImageCacheReading`, and `transport: any HTTPTransport`.

The provider tries three sources in order:
1. **Local VM.** The image has no `/`: call `cli().info(of:)`. If the CLI is unavailable or throws, return nil.
2. **Local cache.** Read `<root>/<host>/<repo>/<tag>/{config.json,manifest.json}`.
   - `protocol ImageCacheReading { func read(_ components: [String], maxBytes: Int) -> Data? }`.
   - Production `FileSystemImageCacheReader(root: ~/.tart/cache/OCIs)` builds the path only from validated components. It resolves symlinks with `realpath` and accepts the result only if it is under the resolved root, so tag → `sha256:` sibling links must work. It enforces `maxBytes`.
3. **Registry.** Only when `host == "ghcr.io"`:
   - Get a token for `repository:<repo>:pull`.
   - Request the manifest with `Accept: application/vnd.oci.image.manifest.v1+json`, capped at 512 KB (pending item 0).
   - Fetch the blob at the tart config layer's digest, capped at 16 KB.
   - The SHA-256 (CryptoKit) must match.
   - The response host must be on the allowlist from item 0.
   - Any other host returns nil.
- Refactor: move the token fetch and bounded GET out of `GHCRXcodeVersionProvider` into a shared `GHCRClient` in `Ghast/Services/Tart/`, keeping the 10 s timeout. The existing `GHCRXcodeVersionProviderTests` must stay green.

Failing tests first, in `GhastTests/TartImageDefaultsProviderTests.swift`, using `FakeTartCLI`, a fake `ImageCacheReading` and `FakeTransport`:
- A local VM wins and the transport is never called.
- The cache wins when present.
- The registry is used when the cache is empty.
- A digest mismatch returns nil.
- An oversized manifest or blob returns nil.
- A non-ghcr ref that isn't cached returns nil, with no request made.
- An invalid ref returns nil, with no request and no read.
- A redirect to a host outside the allowlist returns nil.

Separate test for `FileSystemImageCacheReader` in a temp dir:
- An in-root tag symlink is followed.
- A symlink pointing out of the root returns nil.
- A `..` component is rejected.

Verify: `-only-testing:GhastTests/TartImageDefaultsProviderTests -only-testing:GhastTests/GHCRXcodeVersionProviderTests`.

## 4. Session cache with shared lookups
Add `actor CachingImageDefaultsProvider: TartImageDefaultsProviding` in the same folder:
- Keeps `[String: Task<TartImageDefaults?, Never>]`, so a second call for the same ref while one is in flight awaits the same task.
- Keeps successful results for the session.
- Drops a nil result once its task ends, so a later visit retries (see open question 1).

Failing test: two concurrent calls make one underlying lookup; a nil result is retried on the next call. Use a gated fake provider, no sleeps.
Verify: `-only-testing:GhastTests/TartImageDefaultsProviderTests`.

## 5. Warning counts blank fields at the image value
`VMResourcesWarning.overages(_:image:capacity:)` in `Ghast/Services/Host/HostCapacity.swift`. A nil resource uses the matching `image` value. Unknown values are skipped, as today.
Failing tests in `VMResourcesWarningTests`:
- Blank memory with an image of 40 GB against 64 GB is an overage.
- With no image, it is skipped.
- A typed value overrides the image value.

Verify: `-only-testing:GhastTests/VMResourcesWarningTests`.

## 6. Draft: placeholders, merged sizes, disk note
`Ghast/Models/RunnerConfigurationDraft.swift`:
- Inject `imageDefaults: any TartImageDefaultsProviding`. The default is a `NoImageDefaults` stub that returns nil.
- Add an observable `private(set) var image: TartImageDefaults?`.
- Add `func loadImageDefaults(for imageRef: String) async`. It clears `image` first and sets it only if not cancelled and `runnerID` is unchanged.
- Add `placeholder(for:) -> String`: `"Image: N"`, or `"Image default"` while unknown. Disk shows `"Image default"` when `diskGB` is nil.
- Add `diskNote: String?`, set when the typed disk is valid and ≤ `image.diskGB`. Text exactly as in the spec.
- `overages` passes `image`.
- Saving is untouched.

Failing tests in `RunnerConfigurationDraftTests`:
- Placeholders before, during and after a load, and after a failed load.
- A blank field counts toward overages.
- The disk note shows at equal and lower values, not at higher, blank or invalid values.
- A stale load for a previous runner is ignored.

Verify: `-only-testing:GhastTests/RunnerConfigurationDraftTests`.

## 7. Wiring and view
- `RunnerFlowServices.imageDefaults` defaults to `NoImageDefaults()`.
- `AppDependencies.init(imageDefaults:)` in `GhastApp.swift`. Production builds `CachingImageDefaultsProvider(TartImageDefaultsProvider(cli: TartBackend.systemCLIProvider(launcher: launcher), cache: FileSystemImageCacheReader(), transport: URLSessionTransport()))` once.
- `RunnerDetailViews.swift:52` passes it to `RunnerConfigurationForm`, which passes it to the draft.
- Form:
  - `resourceField` prompt uses `draft.placeholder(for:)`.
  - Add a grey (`.secondary`, `FocusType.subheadline`) disk note directly under the Disk row.
  - `.task(id: savedImage) { await draft.loadImageDefaults(for:) }`, keyed on the runner's saved `.tart(image:)`, not the typed text. Only for VM runners.
- Fixture: new `Ghast/Fixture/FixtureImageDefaults.swift` with a fixed map, no I/O.
  - `ghcr.io/cirruslabs/macos-tahoe-xcode:latest` → 4 / 8 / 140.
  - A second ref used by the warning state → memory 40 GB, so blank × 2 > 64 GB.
  - Inject it in `FixtureDependencies.swift`.
- UI styling is a TDD exception. Snapshots cover it.

Verify: `xcodebuild -project Ghast.xcodeproj -scheme Ghast build`.

## 8. Snapshots
In `GhastTests/FocusMainSnapshotTests.swift` `runningInVM`:
- `vmConfiguration`: CPU and memory blank, disk 100, isolated. Shows `Image: 4`, `Image: 8` and the disk note.
- `vmResourcesWarning`: the 40 GB-memory image, CPU 12, memory blank, disk 200. The warning includes memory, driven by the blank field.
- Keep `vmIsolation*` on typed sizes so they don't change.

Re-record: `TEST_RUNNER_SNAPSHOT_RECORD_MODE=true xcodebuild test … -only-testing:GhastTests/FocusMainSnapshotTests`. Then run again without the variable and expect green. Inspect the changed PNGs (light and dark). Only the vmConfiguration and vmResourcesWarning PNGs should change. Commit them from `GhastTests/__Snapshots__/`.

## 9. Docs
Add one bullet to CLAUDE.md's VM resources paragraph: placeholders come from `TartImageDefaultsProviding` (local VM → cache → ghcr), and blank fields count in the warning. Update the snapshot state list if its wording changes.

## 10. Integration gate
- Check `uptime` first; if load is above ~30, defer.
- Run in the background: `heavy xcodebuild test -project Ghast.xcodeproj -scheme Ghast`. Full suite green, with snapshots.
- Then dispatch `review.security` on `git diff main...HEAD`. Bar: P0/P1 plus anything a realistic image ref or registry response can trigger.

Commit after each step (emoji prefix per CLAUDE.md).

## Risks / open questions
1. **Caching nil results.** The spec says results are kept per ref for the session. The plan caches only successes, so an offline first visit doesn't stick at `Image default` until relaunch. Confirm.
2. **Digest refs (`repo@sha256:…`).** The spec says tag only, so the plan returns nil for them. The cache folder and the registry would both accept the digest, so supporting them is cheap if wanted.
3. **Caps are checked after the download.** `HTTPTransport.send` returns the whole body, so the caps apply once it has arrived. That rejects oversized input, but it doesn't bound memory while downloading. Fixing that needs a streaming transport, which is out of scope. I'd record it as an accepted risk.
4. **`tart get` may omit `Disk`** while a running VM holds an ASIF disk open. `diskGB` is then nil and only that placeholder falls back.

## Orchestrator decisions
1. Cache successes only; a nil result is retried on the next visit (as planned).
2. Digest refs return nil (spec scope is tag refs).
3. Post-download size caps are an accepted risk (no streaming transport).
