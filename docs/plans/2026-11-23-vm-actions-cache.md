# Implementation plan: built-in Actions cache for VM runners

Spec: `docs/specs/2026-11-23-vm-actions-cache.md` (source of truth) · Branch: `feat/vm-actions-cache` · Date: 2026-11-23

## Conventions for every step

- After adding files, run `xcodegen`. Targeted check: `xcodebuild test -project Ghast.xcodeproj -scheme Ghast -only-testing:GhastTests/<Suite>`. The full suite runs once, at Step 16, under `heavy` and in the background.
- Swift Testing. No real network, no real sleeps: inject `AppClock`, `Sleeper` and `HTTPTransport`, and use the fakes in `GhastTests/Mocks`. Real-filesystem tests use a temp directory as the injected root.
- Each step is one commit with an emoji prefix. Steps 2–10 add no UI and no wiring, so they merge safely in any partial state.
- New code lives in `Ghast/Services/Cache/`: `Store/`, `Auth/`, `Server/` and `Twirp/`. Tests go in `GhastTests/Cache*Tests.swift`, and fixtures in `GhastTests/Fixtures/ActionsCache/`.
- Fixture mode (`Ghast/Fixture/`) never starts the server and never touches `~/.ghast/cache`. Step 13 extends `FixtureSafetyTests` to cover this.

## Key DI seams (defined in the step that first needs them)

| Seam | Shape (signature only) | Production / Test |
|---|---|---|
| Clock | existing `AppClock` | system / fixed clock |
| Sleeper | existing `Sleeper` | `Task.sleep` / no-op recorder |
| Cache root | `CacheStore(root: URL, …)` | `~/.ghast/cache` / temp dir |
| Blob writing | `protocol CacheBlobWriting: Sendable { func append(_ bytes: some Collection<UInt8>, to: URL) throws }` | FileHandle / fault injector for a disk-full error (ENOSPC) |
| IDs and sigs | `protocol CacheRandomness: Sendable { func id128() -> String; func signature() -> String }` | `SecRandomCopyBytes` / sequential |
| JWKS | the verifier takes `HTTPTransport` for discovery and JWKS | URLSession / canned responses |
| Upstream | `protocol UpstreamForwarding: Sendable { func forward(_ req: ForwardRequest) async throws -> ForwardResponse }`, with bodies as `AsyncThrowingStream<ByteBuffer, Error>` | URLSession bytes / fake upstream |
| Interfaces | `protocol InterfaceAddressListing: Sendable { func addresses() -> [InterfaceAddress] }` (name, family, address) | `getifaddrs` / list |
| Timings | `struct CacheTiming { uploadIdle = 10 min, entryExpiry = 7 days, sweepInterval = 1 h }` | defaults / small values |
| Server control (for `TartBackend`) | `@MainActor protocol LocalCacheServing { func endpoint(forGateway: String) async -> Result<CacheEndpoint, CacheUnavailable>; func events(vmID:) … }` | `CacheServer` / fake |

## Step 0: spike (gates everything; nothing below starts until it is recorded)

**Done (4967a55):** results and fixtures recorded in the spec's Step 0 section; the design sections were updated to match (34ee42e). The text below is the original brief.

Run on Dionysus. `<image>` is the image of an existing VM runner. Record the results in the spec's Step 0 section, change the spec's status if the design changes, and commit the spec and the fixtures together.

**0.1 Worker patch.** Take the tarball from `RunnerTarballCache`'s directory (or download `actions-runner-osx-arm64-<ver>.tar.gz`) and extract it into a scratch folder.
- Count matches in every dll: `perl -0777 -ne '$n=()=/A\0C\0T\0I\0O\0N\0S\0_\0R\0E\0S\0U\0L\0T\0S\0_\0U\0R\0L\0/g; print "$ARGV $n\n"' bin/*.dll`
- Patch: `perl -0777 -pi -e 's/(A\0C\0T\0I\0O\0N\0S\0_\0R\0E\0S\0U\0L\0T\0S\0_\0)U(\0R\0L\0)/$1O$2/' bin/Runner.Worker.dll`
- Recount the original and the patched string. Then run a real job in a scratch VM with the patched runner and a step that sets its own value and prints `ACTIONS_RESULTS_URL`.
- Confirm that job logs, the step summary and the artifact upload still appear in the GitHub UI. Only the env var name changes, and the runner's own result traffic must not break.
- Proceed if: exactly 1 match in `Runner.Worker.dll`, the job runs, our value survives, and the UI is intact.
- Stop if: 0 or more than 1 match, or another dll also sets the var, or the job or UI breaks. The spec's premise fails.

**0.2 Gateway reachability.**
- Boot a clone: `tart clone <image> ghast-spike && tart run --no-graphics ghast-spike` (in the background).
- `tart exec ghast-spike route -n get default`, then `ifconfig | grep -B4 '<gw>'` on the host. Record the interface name (expect `bridge1xx`).
- Host: `python3 -m http.server --bind <gw> 8765`. Guest: `tart exec ghast-spike curl -sS -m5 http://<gw>:8765/`.
- Check whether `<gw>` is assigned before the guest is reachable (it decides the ordering in Step 12).
- Repeat with `PATH=/usr/local/libexec/ghast:$PATH tart run --no-graphics --net-softnet ghast-spike`. Note the softnet gateway and whether the default policy blocks it.
- Stop if: the gateway is not a host-local `bridge*` address, or a server bound to it is unreachable without isolation.

**0.3 Softnet rule.** Installed Tart is 2.42.0, which also has `--net-softnet-control-fd`. Check, in order:
- (a) whether `--net-softnet-allow` passes its value to softnet's `--allow` unparsed: `tart run --net-softnet-allow 'out proto tcp @host port 8765'`, then curl `:8765` (expect success) and `:8766` (expect blocked);
- (b) whether the control-fd protocol (cirruslabs/softnet source at the installed version) takes rules in the `@host port N` form, and test it the same way;
- (c) anything else in `softnet --help`.

Proceed if (a) or (b) passes both curls. If only a CIDR works (`<gw>/32` opens every host port), record that and **stop for Evan's decision**. Don't build Step 12's isolated path.

**0.4 Request fixtures.**
- Run the falcondev-oss cache server (Docker image or `cargo run`) on the host. Put a scratch logging reverse proxy in front of it; the proxy logs method, path, query, `x-ms-*` and `Range` headers, body length, and JSON bodies, with the bearer token redacted.
- Set the server's public URL to the proxy so signed URLs come back through it.
- Workflow in `ghast-livecheck`: `actions/cache@v4` save and restore, once with a 1 MiB archive and once with a 200 MiB random archive (blocks and block list), plus a restore-keys prefix hit.
- Save the logs as `GhastTests/Fixtures/ActionsCache/{small,large}-{save,restore}.json`: request records only, with no blobs and no tokens.
- Fallback if the falcondev image won't run: derive the sequence from the `@actions/cache` source (`uploadCacheArchiveSDK`, Azure `uploadFile` with block size 64 MiB, concurrency 8, single shot up to 128 MiB) and log it as a fixture debt for the live check.
- Stop if: an endpoint outside the spec's subset appears. Update the spec first.

**0.5 Token claims.** In a livecheck job step, run a node one-liner that decodes `ACTIONS_RUNTIME_TOKEN`'s header and payload, then:
- prints `alg`, `kid`, `iss`, `exp`, `nbf`, `repository_id` and `ac`, never the token or its signature;
- fetches `<iss>/.well-known/openid-configuration` → `jwks_uri` and verifies the token with `crypto.verify('RSA-SHA256', …)` against the JWK whose `kid` matches;
- saves the printed claims (no signature) as `Fixtures/ActionsCache/claims.json`.

Stop if: `iss` is not `https://token.actions.githubusercontent.com`, the JWKS doesn't verify, or `ac` is missing or shaped differently. Step 5 changes in that case.

## Step 1: dependency

- `project.yml`: add the Hummingbird 2 package (`hummingbird-project/hummingbird`, `from: "2.x"`, the latest release older than two weeks) and link it to the `Ghast` target.
- Verify: `xcodegen && xcodebuild -project Ghast.xcodeproj -scheme Ghast build`. Record that the resolved versions (swift-nio and friends) are pinned in `Package.resolved`.

## Step 2: CacheStore model and matching (pure)

- Types: `CacheScope { name: String; permission: CachePermission }`, `CacheRepoID`, `CacheEntry { id, repo, scope, key, version, sizeBytes, createdAt, lastUsedAt, downloadID }`, `CacheIndex` (value type).
- `CacheIndex.match(repo:readScopes:key:restoreKeys:version:) -> CacheEntry?` follows the spec's order: scopes in order, then the primary key and each restore key, exact match before prefix, newest first. `version` must match exactly, as an opaque string.
- Failing tests first (`CacheMatchingTests`):
  - an exact match beats a prefix match;
  - restore keys are tried in order;
  - the newest of several prefix matches wins;
  - the version must match;
  - repo A never sees repo B;
  - a scope that wasn't granted is invisible;
  - earlier scopes win.
- Verify: `-only-testing:GhastTests/CacheMatchingTests`.

## Step 3: CacheStore persistence and upload lifecycle

- `actor CacheStore(root: URL, clock: any AppClock, randomness: any CacheRandomness, writer: any CacheBlobWriting, timing: CacheTiming)`.
- Layout: `index.json` (written atomically), `blobs/<downloadID>` and `uploads/<uploadID>/`. File names are always random hex IDs, never keys.
- API:
  - `reserve(repo:scope:key:version:) -> Reservation?` returns nil if the key and version exist or an upload is pending.
  - `writeBlock` / `writeWhole` / `commitBlocks(order:)` / `finalize(uploadID:sizeBytes:) -> CacheEntry`
  - `lookup(…)`, which updates `lastUsedAt`
  - `blobURL(downloadID:)`, `usage() -> CacheUsage`, `clear()`
- Failing tests first (`CacheStoreTests`):
  - an entry is invisible before finalize;
  - a duplicate reserve returns nil;
  - finalize with the wrong size is rejected;
  - the index survives a reload from disk;
  - a disk-full error during a write aborts that upload, leaves no partial files, and reports the error;
  - `clear()` drops an in-progress upload, and its next write fails cleanly.
- Verify: `-only-testing:GhastTests/CacheStoreTests`.

## Step 4: eviction and expiry

- `CacheStore.evict(capBytes:)` removes least recently used entries until the total is under the cap. It runs after each finalize and at launch.
- `CacheStore.sweep()` removes entries unused for 7 days and uploads with no activity for 10 minutes.
- A `CacheSweeper` loop on the injected `Sleeper` runs it hourly.
- Failing tests (`CacheEvictionTests`):
  - LRU order is by `lastUsedAt`, not `createdAt`;
  - the cap is respected after finalize;
  - an entry exactly 7 days old is kept and one past that is removed (fixed clock);
  - an idle upload is reaped;
  - the sweeper calls `sweep` once per tick and stops on cancel.
- Verify: `-only-testing:GhastTests/CacheEvictionTests`.
- **Gate: `review.concurrency`** on Steps 2–4. Data integrity is at stake: index versus files after a crash, and a download reading while eviction deletes. Removal after `open` is fine on POSIX; confirm the code relies on that.

## Step 5: CacheTokenVerifier

- `actor CacheTokenVerifier(transport: any HTTPTransport, clock: any AppClock, issuer: URL)`.
- `verify(bearer: String) async -> Result<CacheGrant, CacheAuthError>`, where `CacheGrant { repo: CacheRepoID; readScopes: [String]; writeScope: String? }`.
- RS256 with Security.framework: `SecKeyCreateWithData` from the JWK's `n` and `e`, then `.rsaSignatureMessagePKCS1v15SHA256`. JWKS comes from the discovery document, is cached, and is refetched once per unknown `kid`, with a minimum refetch interval so bad `kid`s can't amplify fetches.
- Checks: `alg == RS256` (reject `none` and HS*), `iss`, `exp`, `nbf` when present, and the `repository_id` and `ac` claims. `repository_id` is a JSON string. `ac` is a JSON **string** whose contents decode (a second decode) to `[{Scope, Permission}]`: read is bit 1, write is bit 2. The write scope is the first one with the write bit; read scopes keep the order the token lists them.
- Failing tests (`CacheTokenVerifierTests`). Tests mint tokens with a key generated by `SecKeyCreateRandomKey`, using the claim shape from `claims.json`:
  - valid;
  - bad signature;
  - `alg` set to `none` or HS256;
  - expired;
  - `nbf` in the future;
  - wrong issuer;
  - missing `repository_id` or `ac`;
  - malformed `ac`, and `ac` given as a JSON array instead of a string;
  - `repository_id` given as a number is rejected;
  - an unknown `kid` triggers one refetch;
  - an unreachable JWKS denies the request rather than failing open.
- Verify: `-only-testing:GhastTests/CacheTokenVerifierTests`.

## Step 6: Twirp handlers (HTTP-agnostic)

- `struct CacheTwirpService(store:verifier:signer:baseURL:)` has `handle(method: String, bearer: String?, body: Data) async -> TwirpResponse`, where `TwirpResponse` is a status plus a JSON body.
- The three methods follow the spec, with snake_case coding. A miss or duplicate returns `ok: false`. Errors are `{code, msg}`, and the status mapping follows Twirp: 401 for unauthenticated, 400 for malformed, 404 for an unknown method, 5xx only for a store fault.
- Twirp bodies are capped at 64 KiB.
- `signed_upload_url` is `http://<gw>:<port>/devstoreaccount1/upload/<uploadID>?sig=<sig>` and `signed_download_url` is `http://<gw>:<port>/download/<downloadID>`: at the server root, outside the `/v/<vmToken>/` prefix. This is the shape proven in Step 0.4 (the Azure SDK parses IP-host URLs path-style, so the account-style first segment stays). The upload ID plus `sig`, and the 128-bit download ID, are the capabilities; events come from the Twirp calls, so blob routes need no vmToken.
- int64 fields (`size_bytes` in, `entry_id` out) are JSON strings; `restore_keys` may be absent. A duplicate create is `ok: false` (spec), not falcondev's 409.
- Failing tests (`CacheTwirpTests`):
  - each method's happy path;
  - a miss;
  - a duplicate create;
  - no token or an invalid token → 401 JSON;
  - a write with no write scope → `ok: false`;
  - a restore searches the read scopes in order;
  - an oversize body → 400;
  - never an HTML body.
- Verify: `-only-testing:GhastTests/CacheTwirpTests`.

## Step 7: blob upload (Azure block blob subset)

- `struct CacheBlobUploadHandler(store:)`, under `/devstoreaccount1/upload/{id}`, with routes:
  - a single-shot `PUT` with `x-ms-blob-type: BlockBlob`;
  - `comp=block&blockid=`;
  - `comp=blocklist`, which commits in XML order.
- Responses are 201 with `x-ms-request-id`. An unknown upload ID returns 404. A bad `sig` returns 403, compared in constant time.
- Bodies stream to disk in chunks. Block IDs must be valid base64 and at most 64 bytes, and they map to hashed file names. Block count and block-list size are capped.
- The block-list XML uses `XMLParser` with external entities off and a size cap. A block that is missing from the list fails the commit.
- Failing tests (`CacheBlobUploadTests`):
  - replay `small-save.json` and `large-save.json` in their recorded (out-of-order) arrival order, with generated bytes of the recorded lengths (scaled down for the large case so the test stays fast), and assert that the stored blob equals the concatenation in `<BlockList><Latest>` order;
  - a bad sig → 403;
  - an unknown ID → 404;
  - a list naming a missing block fails;
  - a hostile block ID can't escape the folder;
  - XML with a DOCTYPE or entity is rejected.
- Verify: `-only-testing:GhastTests/CacheBlobUploadTests`.

## Step 8: blob download and ranges

- `struct CacheBlobDownloadHandler(store:)` serves `GET` and `HEAD /download/{id}`.
- `x-ms-range` takes precedence over `Range`, and only a single range is honoured.
- Responses: 206 with `Content-Range`, 416 for an unsatisfiable range, `Accept-Ranges: bytes` and `Content-Length`. The body streams from a file handle.
- Failing tests (`CacheBlobDownloadTests`):
  - full GET;
  - HEAD with no body;
  - `bytes=0-`, a middle range, a suffix `-N`, and an open end;
  - `x-ms-range` wins over `Range`;
  - a range past the end → 416;
  - multiple ranges → 416 (orchestrator decision 2);
  - an unknown ID → 404;
  - replay `*-restore.json` (a plain GET with no range, as `actions/cache` sends it).
- Verify: `-only-testing:GhastTests/CacheBlobDownloadTests`.

## Step 9: passthrough

- `struct CachePassthrough(upstream: any UpstreamForwarding, base: URL)` sends everything that isn't cache traffic to `https://results-receiver.actions.githubusercontent.com`. It keeps method, path, query, body and headers, minus hop-by-hop headers and `Host`, and streams the response back.
- SSRF guard: the path is appended to the fixed base. Reject absolute-form request targets, `//` paths, and any path that would change the host after URL resolution.
- Production `URLSessionUpstream`: the response comes from `bytes(for:)`. The request body is spooled to a capped temp file and sent with `upload(for:fromFile:)`.
- Failing tests (`CachePassthroughTests`, fake upstream):
  - method, path, query and body arrive intact;
  - hop-by-hop headers and `Host` are stripped;
  - `Authorization` is forwarded;
  - an upstream 4xx or 5xx is relayed;
  - an upstream throw → 502 JSON;
  - `http://evil/…` and `//evil/…` targets are rejected;
  - Twirp cache methods are never forwarded.
- Verify: `-only-testing:GhastTests/CachePassthroughTests`.

## Step 10: CacheServer lifecycle and binding

- `@MainActor final class CacheServer: LocalCacheServing`. It wraps a Hummingbird `Application` whose router dispatches to Steps 6–9.
- **Fixed port.** The server picks one random high port (49152–65535, from `CacheRandomness`) when it is created and keeps it until Ghast quits; `port` is readable before any VM boots, because `TartBackend` puts it in the isolation rule on `tart run`'s argv. It never rebinds to a different port.
- **Listeners per bridge address.** `endpoint(forGateway:)` binds the fixed port on that address if it isn't bound yet (idempotent), one Hummingbird server per address sharing one router. The gateway must appear in `InterfaceAddressListing` on a `bridge*` interface; otherwise `CacheUnavailable.addressNotLocalBridge`. Never a wildcard, loopback or `en*` address. On each call, listeners whose address no longer appears are closed (the bridge goes away when its last VM stops, and softnet picks a new /29 per boot). A bind failure (for example `EADDRINUSE` on that address) returns `CacheUnavailable(reason)` for that VM only.
- **Per-VM path segment (orchestrator decision 1):**
  - The Twirp base URL is `http://<gw>:<port>/v/<vmToken>/`, where `vmToken` is random per VM boot and registered and unregistered by `TartBackend`.
  - Twirp requests under an unknown token return 404; passthrough also requires a known token.
  - The segment is stripped before routing and passthrough.
  - It routes cache events to the right runner log with the VM prefix, which the spec requires. Guest IP isn't known reliably.
  - Blob routes (`/devstoreaccount1/upload/…`, `/download/…`) sit at the root (see Step 6).
- `events(vmToken:)` emits `CacheEvent` values: hit or miss with key and size, and save with size. One event per Twirp call, never per block.
- Failing tests (`CacheServerTests`):
  - routing per prefix on a loopback server via an injected test bind policy. Production rejects loopback, so `allowLoopbackForTests` exists only in the test init.
  - an unknown vmToken → 404;
  - the port is chosen once and is the same before and after any bind;
  - a second bridge address gets its own listener on the same port; a repeated call for a bound address binds nothing new;
  - a listener whose address disappears from the interface list is closed on the next call;
  - a gateway on `en0` or loopback (production policy) → unavailable;
  - a bind failure surfaces a reason and leaves other listeners running;
  - one event per call.
- Verify: `-only-testing:GhastTests/CacheServerTests`.
- **Gate: `review.security`** on Steps 5–10:
  - token verification and algorithm confusion;
  - sig and ID entropy;
  - path traversal;
  - XML;
  - SSRF;
  - bind scope (LAN exposure, other local VMs);
  - body and size caps;
  - no tokens in logs.

## Step 11: guest script patch and env line

- `TartGuestScript.make(tarball:)` gains a cache block, and `command(tarball:jitConfig:cacheURL:)` passes the URL as `$2`. The URL never appears in the script text.
- After `tar xzf`, when `$2` is non-empty:
  - count the UTF-16LE string;
  - when the count is exactly 1, patch it with perl and recount (expect 0 of the original);
  - on success, append `ACTIONS_RESULTS_URL=$2` to `.env`;
  - otherwise print one line, `Local cache off: <reason>; this job uses GitHub's cache`, and continue.
- Failing tests (`TartGuestScriptTests`, running the script under `/bin/bash` against a temp folder with a fake `bin/Runner.Worker.dll` and a tarball):
  - patched with the env line;
  - string absent → no env line, one log line, exit 0;
  - two occurrences → the same fallback;
  - empty `$2` → no change from today;
  - the JIT config still arrives as `$1`.
- Verify: `-only-testing:GhastTests/TartGuestScriptTests`.

## Step 12: VM integration and softnet rule

- `LocalRunner.usesLocalCache`, default `true` with `decodeIfPresent`, read live at each boot. Test file: `LocalRunnerMigrationTests`.
- `TartBackend` takes `cache: (any LocalCacheServing)?` (injected, nil in the fixture). In `bootAndRun`, after `waitForGuest`, when `usesLocalCache`:
  1. Before boot: when `usesLocalCache` is on, get the server (created lazily on first use) and its fixed `port`.
  2. `TartArguments.run` builds the isolation rules for every isolated VM, cache on or off (Evan's 0.3 decision; it also closes the 2.5.0 gap where isolated VMs reached every host port): `--net-softnet-block @host` and `--net-softnet-allow` with `out proto udp @host port 53`, plus `out proto tcp @host port <port>` when the cache is on (comma-joined in one value). `TartNetwork.softnet` gains the optional cache port. A shared-network VM gets no rules.
  3. After `waitForGuest`: `tart exec <clone> /sbin/route -n get default` (absolute path: `/sbin` isn't on the exec PATH) and parse the `gateway:` line.
  4. `endpoint(forGateway:)` binds the port there and returns the endpoint; register a vmToken.
  5. Pass `cacheURL` to `TartGuestScript.command`.
- Any failure logs one line (`Local cache unavailable: <reason>`) and boots without the cache. Events become VM-prefixed log lines through `logAppender`. Cleanup unregisters the vmToken.
- Failing tests:
  - `TartBackendCacheTests`: on with a fake server → the command carries the URL and the token is registered;
  - off → no URL and no exec of `route`;
  - server unavailable → one log line, the job still runs;
  - `TartArgumentsTests` / `TartBackendIsolationTests`: an isolated VM's `tart run` args carry exactly `--net-softnet-block @host` and one `--net-softnet-allow` holding `out proto udp @host port 53` (cache off) or that plus `out proto tcp @host port <port>` (cache on), and no other softnet rule; a shared VM carries none;
  - the gateway is parsed from `/sbin/route` output, and an unparseable answer → one log line, no cache;
  - an event → one prefixed line;
  - cleanup unregisters the token.
  - `TartCLIParsingTests` / `ProcessTartCLITests` for any new argv.
- Verify: `-only-testing:GhastTests/TartBackendCacheTests -only-testing:GhastTests/TartBackendIsolationTests -only-testing:GhastTests/LocalRunnerMigrationTests`.
- **Gate: `review.security`** on the isolation rule and the gateway trust. The guest reports the gateway, so the bridge check from Step 10 must stay the authority.

## Step 13: composition root and settings model

- `AppSettings.cacheSizeCapGB` (default 50, at least 1).
- `AppDependencies` builds the `CacheStore` (root `~/.ghast/cache`, owner-only), the verifier, `CacheServer` and the sweeper. It runs evict and sweep at launch, and the server starts lazily.
- `RunnerFlowServices` gains `cacheStats: any CacheStatsProviding` (usage, cap, clear) for the Settings view, with a fixture fake.
- `applicationShouldTerminate` stops the server after the runners.
- `applicationShouldTerminate` also calls `CacheStore.flush()`, so restore recency (`lastUsedAt`, otherwise saved with the next index write or the hourly sweep) survives a quit (concurrency review, accepted risk).
- Failing tests:
  - `AppSettingsTests` (default and clamp);
  - `FixtureSafetyTests`: fixture mode creates no cache folder and no server;
  - `AppStartupTests`: launch sweep with a fake store.
- Verify: the three suites, targeted.

## Step 14: Configuration tab switch

- `RunnerConfigurationForm` and `RunnerConfigurationDraft` get a "Use local cache" toggle for VM runners only, with the help text from the spec.
- Tests: `RunnerConfigurationDraftTests` covers round-trip and VM-only. A new `FocusMainSnapshotTests` state, `vmCache`, in light and dark. Record, then re-run green.
- Verify: `TEST_RUNNER_SNAPSHOT_RECORD_MODE=true xcodebuild test … -only-testing:GhastTests/FocusMainSnapshotTests`, then without the variable.

## Step 15: Settings › General › Cache

- `GeneralSettingsView` gets a Cache section: space used, a size cap stepper or field in GB (applying the cap triggers eviction), and Clear Cache behind a confirmation dialog.
- Tests:
  - a `CacheSettingsModel` unit test: the cap edit evicts, confirmation gates clearing, usage formatting;
  - the `FocusSettingsSnapshotTests` General state re-recorded with Cache, in light and dark.
- Verify: `-only-testing:GhastTests/FocusSettingsSnapshotTests`, plus the model suite.
- Steps 11–15 get a normal `review` (Step 12 also has its security gate).

## Step 16: integration gate, docs and live check

- Full suite: `heavy xcodebuild test -project Ghast.xcodeproj -scheme Ghast` in the background, after checking load. Fidelity capture for configuration and settings-general.
- CLAUDE.md gets an architecture bullet for the cache (the server, binding rule, vmToken prefix, patch and fallback), and the snapshot state list is updated.
- Live check in `blackpaw-studio/ghast-livecheck`:
  - run 1 saves (`actions/cache@v4`), run 2 restores;
  - the hit line is visible in the runner log;
  - on both an isolated and a non-isolated VM runner;
  - plus `actions/upload-artifact@v4` to prove passthrough.
- Also on the isolated VM, with the cache on and off: a second host port and the LAN are unreachable, and DNS and the internet work.
- Post the run links and log excerpts to Evan via `leo_chat_post`.

## Risks

- **Runner self-update or new versions:** the string may move or be duplicated. The patch counts it first and falls back to GitHub's cache, so the risk is silent loss of the feature, not failure. The log line makes it visible.
- **`ACTIONS_RESULTS_URL` serves more than cache:** passthrough has to be faithful. Step 0.1 and the live artifact check cover it, but job summaries and attestations are only covered if the livecheck workflow uses them.
- **Bridge address appears only after vmnet starts:** this ordering is resolved in Step 0.2. If isolated runs need the rule at `tart run` time, the port must be bound before boot.
- **Hummingbird and swift-nio size:** a new transitive dependency tree in a notarized app. Check the binary size delta and the Sparkle build at Step 16.
- **Disk:** the 50 GB default can fill a small disk alongside `~/.tart`. Disk-full aborts only the upload, as the spec requires. Steps 1–15 add no warning, by design.
- **JWKS outage:** the cache misses every request (it fails closed). Correct per the spec, but it looks like "cache broken".

## Open questions for the orchestrator

1. **Per-VM path segment (`/v/<vmToken>/`) in `ACTIONS_RESULTS_URL`:** the spec says `http://<gateway>:<port>/`, but routing log lines to the right runner and VM needs a per-VM handle. Is the segment acceptable as an implementation detail, or should Evan confirm it?
2. **Multi-range downloads:** return a full 200 or a 416? The toolkit sends single ranges only. I suggest 416.
3. **Server stop policy:** the spec only says it starts on the first boot. The plan keeps it running until quit. Should it stop when no cache-enabled VMs remain?
4. **Step 0.3 CIDR-only outcome:** this needs Evan's decision before Step 12. Options: accept `<gw>/32`, give up isolated-VM caching, or have the helper wrapper inject `--allow`.

## Orchestrator decisions on the open questions (2026-11-23)

1. ~~Per-VM path segment `/v/<vmToken>/` is accepted as an implementation detail.~~ **Superseded 2026-11-24 (Evan):** the live check showed actions/toolkit resolves `/twirp/…` against `ACTIONS_RESULTS_URL` with a leading slash, which drops the path, so every call hit the root and got 404. Each VM now gets its own port, chosen at registration before boot; its URL is `http://<gateway>:<port>/`, its softnet rule allows only that port, and the port routes its events. Requests are still verified by the job's runtime token. The `/v/<vmToken>/` references in the steps above describe the first design.
2. Multi-range requests get 416.
3. The server keeps running until Ghast quits (it is bound to the VM bridge only).
4. If Step 0.3 finds only a CIDR rule is possible, stop and ask Evan; don't pick an option.
5. Step 0.3 (Evan, 2026-11-23): every isolated VM, cache on or off, gets `--net-softnet-block @host` plus allow `out proto udp @host port 53`, and `out proto tcp @host port <cachePort>` when the cache is on. The cache port is chosen before boot so it can go on the argv before the gateway is known (per app run at first; per VM since 2026-11-24, see 1).
