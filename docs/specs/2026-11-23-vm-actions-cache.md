# Built-in Actions cache for VM runners

Date: 2026-11-23 · Status: draft

## Goal

VM runners boot a fresh clone for every job, so `actions/cache` restores from
GitHub's hosted cache over the internet every time (and saves count against the
repo's cache quota). Ghast runs a cache server on the Mac that speaks GitHub's
cache API v2, so existing workflows (`actions/cache`, the `cache:` option of
`setup-*` actions, BuildKit `type=gha`) hit a local cache with no workflow
changes and no setup.

Decided with Evan (2026-11-23):
- Native in Ghast; one cache per Mac. No sharing between Macs; each warms up on
  its own.
- VM runners only. Host runners are out of scope (their self-update silently
  reverts the runner patch).
- On by default for every VM runner, with a per-runner switch.
- Store in `~/.ghast/cache/`, 50 GB cap, least recently used evicted first, and
  entries unused for 7 days removed.

## Background: how a job finds the cache

`@actions/cache` (v2 service) sends every cache call to
`${ACTIONS_RESULTS_URL}twirp/github.actions.results.api.v1.CacheService/<Method>`.
The runner sets `ACTIONS_RESULTS_URL` from the job message at the start of every
job, overwriting any value we set. Ghast therefore patches the runner's
`bin/Runner.Worker.dll`: the UTF-16LE string `ACTIONS_RESULTS_URL` becomes
`ACTIONS_RESULTS_ORL` (same length), so the runner writes a dummy variable and
ours survives. The same URL serves artifacts and job summaries, so anything that
isn't a cache call is forwarded to GitHub. Reference implementation:
github.com/falcondev-oss/github-actions-cache-server (MIT).

## Step 0: spike (gates the design)

Run on Dionysus with a scratch VM; record results here before building.

1. The macOS runner tarball contains `bin/Runner.Worker.dll` with the UTF-16LE
   string exactly once; a byte patch in the guest (perl, no extra tools) works,
   and the runner still starts and runs a job.
2. The guest's default gateway (`route -n get default`) is the host's vmnet
   address, with and without `--net-softnet`, and a server on the host bound to
   that address is reachable from the guest.
3. Isolated VMs: find how Ghast passes the softnet rule
   `out proto tcp @host port <port>` (Tart's `--net-softnet-allow` takes CIDRs;
   check for a rule-passing flag in the installed Tart). If only a CIDR is
   possible, record what that opens (every host port) and stop for a decision.
4. Capture the real request sequence of `actions/cache@v4` save and restore, for
   a small (<128 MiB, single PUT) and a large (>128 MiB, blocks + block list)
   archive, as test fixtures.
5. Confirm a job token's claims: `iss`, `repository_id`, `ac` (scopes with
   read/write bits), and that the JWKS at
   `https://token.actions.githubusercontent.com` verifies it.

## Design

### CacheServer
Hummingbird 2 (SwiftNIO) HTTP/1.1 server inside Ghast.
- Twirp JSON (snake_case): `CreateCacheEntry {key, version}` →
  `{ok, signed_upload_url}`; `FinalizeCacheEntryUpload {key, version,
  size_bytes}` → `{ok, entry_id}`; `GetCacheEntryDownloadURL {key,
  restore_keys, version}` → `{ok, signed_download_url, matched_key}`. A miss is
  `ok: false`, not an error. Errors are JSON `{code, msg}`.
- Upload (Azure block blob subset): `PUT /upload/{id}?sig=…` single shot
  (`x-ms-blob-type: BlockBlob`); `&comp=block&blockid=…` per block;
  `&comp=blocklist` commits in the order the XML lists. 201 with
  `x-ms-request-id`. Unknown id 404, bad `sig` 403.
- Download: `GET`/`HEAD /download/{id}`, honouring `x-ms-range` then `Range`
  (one range), 206 + `Content-Range`, 416 on bad range, `Accept-Ranges: bytes`.
- Everything else is forwarded to `https://results-receiver.actions.githubusercontent.com`
  with method, path, query, body and headers (minus hop-by-hop headers and
  `Host`), and the response streamed back.
- Bodies stream to disk; nothing holds a whole archive in memory.

### CacheTokenVerifier
- Verifies the bearer JWT (RS256) with keys from the issuer's OIDC discovery
  document, cached and refreshed on an unknown `kid`. Checks `iss` and `exp`
  (and `nbf` if present).
- Repo is `repository_id`; scopes come from `ac` (read bit 1, write bit 2).
  Save goes to the first write scope; restore searches the read scopes in the
  order GitHub grants them. No valid token: 401, and the client treats it as a
  miss.

### CacheStore
- Index plus archive files in `~/.ghast/cache/`, keyed by repo, scope, key and
  version (`version` is compared as an opaque string).
- Matching: for each read scope in order, the primary key then each restore
  key; exact match before prefix match; newest first.
- An entry is visible only after finalize. A second create for an existing
  key+version in the same scope returns `ok: false` (client skips the save).
- Eviction: after each finalize and at launch, remove least recently used
  entries until under the cap (50 GB, editable in Settings); remove entries
  unused for 7 days and uploads with no activity for 10 minutes (hourly).
- Upload and download IDs are random 128-bit values; upload URLs also carry a
  per-upload `sig`.

### Listening
- Binds only to the host's vmnet address (the address guests use as their
  gateway), on a random port, never to LAN interfaces. Starts when the first
  cache-enabled VM boots; restarts if the address changes.
- If the server can't start, the VM boots without the cache and the runner log
  says why.

### VM integration
- `LocalRunner.usesLocalCache` (default true). Read at each boot.
- Guest script, after unpacking the runner: patch `Runner.Worker.dll`, check the
  patch applied, then set `ACTIONS_RESULTS_URL=http://<gateway>:<port>/` in the
  runner `.env`. If the string isn't found or the patch fails, skip the env
  line and log one line; the job uses GitHub's cache.
- Isolated VMs get the softnet rule allowing TCP to the host on the cache port
  only (per Step 0.3).
- Runner log lines (with the VM prefix): cache hit/miss with key and size, and
  saves with size. One line per call, no per-block noise.

### UI
- Configuration tab (VM runners): "Use local cache" switch, with help text
  saying workflows need no changes and caches stay on this Mac.
- Settings › General › Cache: space used, size cap (GB), Clear Cache (with
  confirmation). Clearing while an upload is in progress drops that upload.

## Error handling

The cache must never fail a job. Client behaviour (from the toolkit): restore
errors become warnings and a miss; save errors become warnings. The server
returns `ok: false` or Twirp JSON errors, never HTML, and 5xx only for genuine
server faults (the client retries those five times with backoff). Disk full
during upload: abort that upload, return an error, log one line.

## Testing

- Unit: key and restore-key matching, scope isolation (repo A never sees repo
  B; a branch reads only its granted scopes), eviction order and expiry, token
  verification with a test signing key (bad signature, expired, wrong issuer,
  missing claims), Twirp handlers, single-shot and block uploads replayed from
  the Step 0.4 fixtures, range downloads, passthrough (fake upstream).
- Guest script: patch step and env line, including the not-found fallback.
- Snapshots: Configuration with the switch; Settings › General with Cache.
- Live, before merge, in `blackpaw-studio/ghast-livecheck`: a workflow that
  saves with `actions/cache`, then a second run that restores (hit logged), on
  an isolated and a non-isolated VM runner; plus an artifact upload to prove
  passthrough.

## Not included

Host runners; sharing between Macs; the v1 cache API; per-repo size limits;
`ACTIONS_CACHE_MODE` handling beyond what the client does itself.
