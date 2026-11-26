# Tart Storage: implementation plan

Spec: `docs/specs/2026-11-25-tart-storage.md`. If this plan and the spec disagree, the spec wins. Every test is Swift Testing, written first and seen to fail before the code that makes it pass.

**Test command** (`<Suite>` changes per step; run `xcodegen` first when a file is added):
`xcodebuild test -project Ghast.xcodeproj -scheme Ghast PRODUCT_BUNDLE_IDENTIFIER=net.evancoleman.ghast.testhost -only-testing:GhastTests/<Suite>`

## Orchestrator decisions
1. **A blocked pull posts one notification**: `<runner> can't pull <short image ref>: not enough disk space`, through `NotificationPolicy` and the existing user setting, from the same `RunnerProcessExit` path (add a reason case rather than a new channel). Reason: a VM runner going down overnight in silence is the #38 failure mode.
2. **A running local VM** (`Running: true`) gets Remove disabled with help text `This VM is running.`

## Step 1: `tart list` gets the extra fields; pulls set `TART_NO_AUTO_PRUNE`
- `Ghast/Services/Tart/TartJSON.swift`: `ListRow` and `TartVMEntry` gain `sizeGB: Int?` (`Size`), `diskGB: Int?` (`Disk`), `accessed: Date?` (`Accessed`). All three are optional so `ensureImage` keeps working if Tart leaves a field out. Check the real `Accessed` format with a read-only `tart list --format json` and decode exactly that. Put a fixture row in the test.
- `TartCLI.swift`, `ProcessTartCLI.pull`: environment = `baseEnvironment` + `TART_NO_AUTO_PRUNE=1`. No other call changes. `TartArguments` is unchanged; `delete(_:)` takes a digest ref or a name.
- Failing tests:
  - `TartCLIParsingTests`: decodes the new fields; a row without them still decodes.
  - `ProcessTartCLITests`: the pull's environment has `TART_NO_AUTO_PRUNE == "1"`, and `run` with a shared network still gets `nil`.
- Update `FakeTartCLI` for the new `TartVMEntry` shape.

## Step 2: exact image disk bytes and free bytes
- `TartImageDefaults.swift`: `TartManifestInfo` and `TartImageDefaults` gain `diskBytes: Int64?` from the `uncompressed-disk-size` annotation, before rounding. It is dropped whenever `diskGB` is. `diskGB` stays as is for the Resources UI. The provider passes it through; it is nil for a local VM (`tart get` reports whole GB).
- `HostCapacity`: add `freeDiskBytes() -> Int64?`. `SystemHostCapacity` reads `volumeAvailableCapacityForImportantUsage` and derives `freeDiskGB()` from it. Fakes and the fixture gain the same method.
- Failing test: `TartImageDefaultsParsingTests`, where an annotation of `150_323_855_360` gives exactly that `diskBytes`.

## Step 3: the space check as a pure function, plus the error
- New `Ghast/Services/Tart/PullSpaceCheck.swift`: `reserveBytes = 128 MiB`, and `shortfall(image:requiredDiskBytes:freeBytes:) -> TartBackendError?`. It returns nil when a size is unknown or when `disk + reserve <= free`.
- `TartBackendError.insufficientSpace(image:neededBytes:freeBytes:)`:
  - its message is the spec copy exactly, with the short ref, "needs" in decimal GB rounded up and "free" rounded down;
  - `isTransient` is false.
- Failing tests in `PullSpaceCheckTests`: blocks when the image won't fit, passes at the exact boundary, returns nil when a size is unknown, and the message matches the spec example.

## Step 4: `TartBackend` checks before pulling
- `TartBackend.init` gains `imageDefaults: any TartImageDefaultsProviding = NoImageDefaults()` and `capacity: (any HostCapacity)? = nil`. A nil `capacity` skips the check.
- `ensureImage`: after the `isOCIRef` guard and before `isPulling = true`, look up `diskBytes` and `freeDiskBytes`, then throw any `shortfall`. Clones are not checked.
- `GhastApp.swift`: one shared `CachingImageDefaultsProvider` and one `SystemHostCapacity`, passed to both `TartBackend` and `AppDependencies`.
- Failing tests in `TartBackendPullSpaceTests`, with `FakeTartCLI`, `FakeImageDefaults` and `FakeHostCapacity`:
  - when it doesn't fit, `pull` is never called and the log has the spec line;
  - when it fits, the image is pulled;
  - when the size is unknown, the image is pulled.

## Step 5: a blocked pull doesn't retry and keeps the run intent
- `RunnerBackendHost.recordExit` gains `retries: Bool`, defaulting to `true` through a protocol extension.
- `RunnerService.recordExit`: when `retries == false` and `shouldBeRunning` is set, the state becomes `.exited(exit)`. There is no `recovery.decide` or `schedule`, the intent is kept, and decision 1's notification posts.
- `TartBackend` threads `retries: Self.isRecoverable(failure)` through `shutDown`/`drain`/`finish`. It is false only for `.insufficientSpace`.
- Failing tests:
  - `RunnerRecoveryTests`: a `retries: false` exit reads `.exited`, keeps the intent and leaves nothing pending in the sleeper. A later `start` runs with the attempt count reset.
  - `TartBackendPullSpaceTests`: the runner ends `.exited` with its intent kept, and there is no second `list`/`pull` after the sleeper advances.
  - Notification policy test: the blocked-pull copy, and a single post.

## Step 6: resolve tags to digests
- New `Ghast/Services/TartStorage/TartCacheLinkReading.swift`:
  - protocol `digest(forTag: TartImageRef) -> String?`;
  - `FileSystemTartCacheLinkReader(root: ~/.tart/cache/OCIs)`. It reads only `<host>/<repo>/<tag>`, with the same component checks as `FileSystemImageCacheReader`. The link target's last component must match `sha256:[0-9a-f]{64}` and stay inside the repo folder; anything else returns nil.
- Failing tests in `TartCacheLinkReaderTests`, using a temp folder: a symlink resolves; a dangling link, a target outside the repo, a name that isn't a digest, and a plain folder each return nil.

## Step 7: the inventory as a pure function
- New `Ghast/Services/TartStorage/TartStorageInventory.swift`: `make(entries:digestForTag:runnerImages:pullingImages:)` returns `pulled`, `localVMs` (each sorted by size, largest first) and `totalBytes`.
- `StoredImage` fields:
  - `displayName`: the short ref, or `repo@sha256:` plus 12 hex digits. The helper lives beside `TartImageRef`; step 3 uses it too.
  - `deleteRef`: the digest ref for a pulled image, the name for a local VM.
  - `sizeBytes`: the digest row's `Size` × 10⁹.
  - `accessed`, `usedBy`, `isPulling`, `isRunning`, `isLocal`, `removeBlockReason`.
- Rules:
  - a digest row and the tags that resolve to it are one image, counted once;
  - a tag that can't be resolved is its own row, deleted by tag;
  - `ghast-*` (`TartBackend.clonePrefix`) is hidden;
  - a runner's image matches by tag or digest after `TartImageRef.parse` normalises it (a missing tag means `latest`).
- `unusedPulled` is the pulled images with no users that aren't pulling. It never includes a local VM.
- Failing tests in `TartStorageInventoryTests`, one per spec bullet, plus decision 2.

## Step 8: `TartStorageModel` (follows `CacheSettingsModel`)
- `@MainActor @Observable`. It injects the CLI provider, `capacity`, `links`, `clock`, and a `usage` closure built from `RunnerService` (runner images, and images being pulled).
- It holds `inventory`, `freeBytes`, `headerText` (decimal GB) and `rowErrors`.
- Actions:
  - `refresh()`;
  - `requestRemove`/`confirmRemove`;
  - `requestRemoveUnused`/`confirmRemoveUnused`, which deletes in order, keeps failures inline on their rows, then refreshes;
  - `pullsChanged`, which refreshes when the pulling set shrinks.
- Confirmation copy follows the spec. It re-checks `removeBlockReason` just before each delete.
- Failing tests in `TartStorageModelTests`, where `FakeTartCLI` records deletes:
  - Remove deletes the digest ref;
  - a failed delete keeps the row and shows the error;
  - Remove Unused deletes only unused pulled images;
  - nothing is deleted without a confirmation;
  - a pull finishing triggers a refresh.

## Step 9: wiring and fixture
- `AppDependencies` builds `tartStorage` and injects it beside `cacheSettings`.
- The fixture gets canned `list` rows: two pulled images (tag and digest rows), one of them used; one local VM; one `ghast-*` clone, which must not show; and a fixed clock. It never runs real `tart`.
- Verify: `FixtureSafetyTests`, `GhastAppTests`, `AppStartupTests`.

## Step 10: the view (UI styling, no test-first)
- `Ghast/Views/Focus/Settings/TartStorageSection.swift`: a `FocusFormSection(caption: "Tart Storage")` after `cacheSection`. It contains the header, pulled rows, a `Local VMs` group, per-row **Remove…** (disabled, with `.help(reason)`), inline errors, **Remove Unused…** and the confirmation dialogs.
- `.task { await model.refresh() }`; `.onChange` of the images being pulled calls `pullsChanged`.

## Step 11: snapshot
- `FocusSettingsSnapshotTests`: the General case renders the section, in light and dark. Record, re-run without the variable, inspect the PNGs at native size, then commit the baselines.
- Run `Scripts/fidelity/capture.sh settings-general` (with `--dark` too) under `heavy`, in the background.

## Step 12: CLAUDE.md
Add a Tart Storage bullet under Runner Management covering:
- the model and inventory, with tags resolved to digests;
- deletes by digest, local VMs never bulk-removed, `ghast-*` hidden;
- the pull check (`diskBytes` + 128 MiB): `insufficientSpace` → `recordExit(retries: false)`, the intent kept, one notification;
- `TART_NO_AUTO_PRUNE=1`;
- the spec path.

Also add the snapshot case to the Snapshot Testing list.

## Step 13: integration gate
Check the load average, run the full suite under `heavy` in the background, then a fresh-context review of `git diff main...HEAD`.

Commit after each step with an emoji-prefixed message.

## Risks
- **Units:** `freeDiskGB` is GiB, while Tart and the manifest use decimal units. This plan uses bytes throughout and formats as decimal GB. The Resources warning is left alone.
- **`Accessed` format:** a wrong guess would break `list()` for every VM runner. The field is optional and is checked against real output.
- **Stale estimate:** the cached estimate is stale for the session if a tag moves. Tart's own check (with no-prune) is the backstop.
- **Tag resolution:** if the cache layout changes, tags stop resolving and show as separate rows (possible double count). Deletes are still safe.
- **`recordExit` changes shape:** `BareMetalBackend` keeps `retries: true`.
