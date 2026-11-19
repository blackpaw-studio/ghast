# Plan — On-demand Tart VM runners

Spec: `docs/specs/2026-11-18-tart-on-demand.md` (wins on conflict). Branch `feat/tart-on-demand`.
Protocol reference: `github.com/actions/scaleset` @ `716908e` (2026-11-07): `client.go`, `session_client.go`, `types.go`, `errors.go`, `http_client.go`, `listener/listener.go`, `examples/dockerscaleset/{main,scaler,config}.go`, `README.md`.
`T <Suite>` = `xcodebuild test -project Ghast.xcodeproj -scheme Ghast -destination platform=macOS -only-testing:GhastTests/<Suite>`. Run `xcodegen` after adding files.

## Protocol shapes (port exactly)

**Auth handshake** (`client.go` `updateTokenIfNeeded` / `getActionsServiceAdminConnection`):
1. Registration token: `POST https://api.github.com/{repos/{o}/{r}|orgs/{org}}/actions/runners/registration-token`, `Authorization: Bearer <oauth>` → **201** `{"token","expires_at"}` (existing `GitHubAPIService.createRegistrationToken(for:)`).
2. Admin connection: `POST https://api.github.com/actions/runner-registration`, headers `Content-Type: application/json`, `Authorization: RemoteAuth <registration token>`, body `{"url":"https://github.com/<org>[/<repo>]","runner_event":"register"}` → 2xx `{"url": <actions service base>, "token": <JWT admin token>}`; missing url/token = error. Retries **401/403 on this call only** (fresh reg token "not always usable immediately"), default budget max 4 retries, exponential backoff.
3. Admin token: read `exp` from the JWT payload (base64url middle segment, unverified). Refresh (1–2) when `now + 60 s >= exp`. One refresh in flight; others await it.
4. Actions-service requests: `<url>/<path>`, `Authorization: Bearer <admin token>`, `Content-Type: application/json`, query `api-version=6.0-preview` unless present.

**Endpoints** (`S` = `_apis/runtime/runnerscalesets`):

| Call | Request | Success |
|---|---|---|
| Get scale set by name | `GET S?runnerGroupId=<id>&name=<name>` | 200 `{"count","value":[RunnerScaleSet]}`; 0 → nil, 1 → value[0], >1 → error |
| Create | `POST S` body RunnerScaleSet | **200** RunnerScaleSet |
| Delete | `DELETE S/<id>` | **204** (404 = gone) |
| Runner group by name | `GET _apis/runtime/runnergroups/?groupName=<n>` | 200 `{"count","value":[{"id","name","size","isDefaultGroup"}]}` |
| JIT config | `POST S/<id>/generatejitconfig` `{"name","workFolder"}` | 200 `{"runner":{"id","name","runnerScaleSetId"},"encodedJITConfig"}` |
| Create session | `POST S/<id>/sessions` `{"ownerName":<host>}` | 200 RunnerScaleSetSession |
| Refresh session | `PATCH S/<id>/sessions/<sessionId>` (no body) | 200 RunnerScaleSetSession |
| Delete session | `DELETE S/<id>/sessions/<sessionId>` | 204 |
| Acquire jobs | `POST S/<id>/acquirejobs` JSON array of `runnerRequestId` (int64) | 200 `{"count","value":[int64]}`; **auth `Bearer <messageQueueAccessToken>`** |
| Get message | `GET <messageQueueUrl>[&lastMessageId=N if N>0]` | 200 message / **202 = none**; 401 → refresh session, retry once |
| Ack message | `DELETE <messageQueueUrl path>/<messageId>` (keep query) | 204; 401 → refresh, retry once |

Get-message headers: `Accept: application/json; api-version=6.0-preview`, `Authorization: Bearer <messageQueueAccessToken>`, `X-ScaleSetMaxCapacity: 2`. Server holds ~50 s; client per-attempt cap **120 s** → `URLRequest.timeoutInterval` ≥ 120.

Default group: reference hardcodes `runnerGroupId = 1` for "default"; reuse existing `TartBackend.runnerGroupID(for:)` (1 for repo, REST group ids for org). No extra lookup.

**JSON** (`types.go`):
- `RunnerScaleSet {id, name, runnerGroupId, runnerGroupName, labels:[{name,type}], "RunnerSetting":{disableUpdate}, createdOn, runnerJitConfigUrl, statistics}` — `RunnerSetting` capitalised.
- Create body: `{"name":N,"runnerGroupId":G,"labels":[{"name":N,"type":"System"}],"RunnerSetting":{"disableUpdate":true},"createdOn":"0001-01-01T00:00:00Z"}`.
- `RunnerScaleSetSession {sessionId (uuid), ownerName, runnerScaleSet, messageQueueUrl, messageQueueAccessToken, statistics}`.
- `RunnerScaleSetStatistic {totalAvailableJobs, totalAcquiredJobs, totalAssignedJobs, totalRunningJobs, totalRegisteredRunners, totalBusyRunners, totalIdleRunners}`.
- Message: `{"messageId","messageType":"RunnerScaleSetJobMessages","body":<STRING>,"statistics"}`; other `messageType` = error. `body` is a JSON string of an array (decode twice). Element `messageType` ∈ `JobAvailable` (+`acquireJobUrl`), `JobAssigned`, `JobStarted` (+`runnerId`,`runnerName`), `JobCompleted` (+`result`,`runnerId`,`runnerName`); common `runnerRequestId` (int64), `jobId`, `jobDisplayName`, `repositoryName`, `ownerName`, `requestLabels`, ISO-8601 `queueTime`, `scaleSetAssignTime`, `runnerAssignTime`, `finishTime`. Unknown types ignored.
- Errors `{"typeName","message"}`: `AgentExistsException` → exists; `AgentNotFoundException` → not found; `JobStillRunningException` → job still running. 400 bad request, 401 unauthorized, 404 not found, 409 conflict. Strip UTF-8 BOM first (`errors.go` `trimByteOrderMark`).
- Retry (`README.md`): transport errors, 5xx except 501, 429 (honour `Retry-After`) are transient. Rate-limited 403 = rate limit, not auth.

**Listener flow** (`listener.go`, `scaler.go`): create session → initial demand = `session.statistics.totalAssignedJobs` → loop `GetMessage(lastMessageId, 2)`: 202 → continue; else if any `JobAvailable` → `AcquireJobs([runnerRequestId…])` (required for assignment), demand = `statistics.totalAssignedJobs`, ack in a non-cancellable task, `lastMessageId = messageId`. Target = min(2, assigned) vs live VMs (booting + running).

**Naming:** reference only requires non-empty and "unique within a runner group". The 45-char limit online is ARC's Helm install name, not GitHub's. VM names = existing `NewRunnerName` rules + trimmed non-empty. Existing scale set with the name = reuse.

**OAuth risk / fallback signal:** OAuth token only touches step 1 (already used for `config.sh`). `ScaleSetError.authRejected` (sole fallback trigger) = non-rate-limit 401/403 on `runner-registration` after retries, or on the first `GET`/`POST S`. 401/403 in step 1 = existing auth error (REST would fail too), no fallback.

## Steps (one commit each)

1. **Wire models** — `Ghast/Services/ScaleSet/ScaleSetModels.swift` (all shapes, double-decoded message body, `ActionsExceptionBody` mapper). Test first `ScaleSetModelsTests`: session with stats; message with 4 types + unknown; non-`RunnerScaleSetJobMessages` rejected; JIT; list count 0/1/2; create body encodes `RunnerSetting` and `System` labels; BOM error body.
2. **Actions-service client + handshake** — `Services/ScaleSet/ActionsServiceClient.swift` (`@MainActor`; injected `HTTPTransport`, `GitHubAPIServiceProtocol`, `AppClock`): `scaleSet(named:groupID:)`, `createScaleSet(name:groupID:)`, `deleteScaleSet(id:)` (404 ok), `jitConfig(scaleSetID:name:workFolder:)`. `ScaleSetError {authRejected, notFound, conflict, rateLimited, transient(underlying), badResponse}`. Test first `ActionsServiceClientTests`: handshake order/headers/body; `api-version` + `Bearer <jwt>`; JWT reuse before `exp-60s`, refresh after (FakeClock); 403 on runner-registration exhausted → `.authRejected`; rate-limited 403 → `.rateLimited`; 401 on create → `.authRejected`; delete 404 ok.
3. **Message session** — `Services/ScaleSet/ScaleSetMessageSession.swift`: `create(ownerName:)` → initial stats, `nextMessage(lastID:)` (202 → nil), `ack(id:)`, `acquire(requestIDs:)`, `close()`; 401 on queue/acquire/ack → PATCH refresh, retry once; 120 s poll timeout. Test first `ScaleSetMessageSessionTests`: ownerName; 202 nil; 200 stats; `lastMessageId` only >0; `X-ScaleSetMaxCapacity: 2`; ack path + query; 401 → PATCH + retry; acquire uses queue token; close DELETE 204.
4. **`JobDemandSource` + `ScaleSetDemandSource`** — `Services/Demand/JobDemandSource.swift`:
   ```swift
   @MainActor protocol JobDemandSource: AnyObject {
     func run(onDemand: @escaping @MainActor (Int) -> Void) async throws   // until cancelled
     func jitConfig(runnerName: String, workFolder: String) async throws -> JITRunner
     func close() async                 // Stop/Quit: delete session (REST no-op)
     func deleteRemote() async throws   // Remove: delete scale set, 404 ok (REST no-op)
   }
   ```
   Find-or-create set `runner.name` in `runnerGroupID(for:)`; session owner `Host.current().localizedName ?? "ghast"`; listener flow; 409 on session create = transient. Test first `ScaleSetDemandSourceTests`: reuse existing set; create when 0; initial stats → onDemand; JobAvailable → acquire → demand → ack order; 202 no callback; JIT uses set id; close deletes session; deleteRemote 404 ok.
5. **REST conditional GETs** — `fetchWorkflowRuns(repo:status:etag:)`, `fetchJobs(repo:runID:etag:)` → `Conditional { .notModified, .fresh(value, etag) }`, `If-None-Match`, 304 not an error; update `MockGitHubAPIService`, `FixtureGitHubAPIService`. Test first `GitHubAPIServiceTests`.
6. **`RESTPollingDemandSource` + `DemandSourceFactory`** — every 15 s (Sleeper): runs `status=queued` and `in_progress`, their jobs, ETags per URL; demand = queued + in_progress jobs whose `labels` contain `runner.name` (case-insensitive); JIT via `generateJITConfig(labels: [name, "self-hosted","macOS","ARM64"])`. Factory: scale set; `.authRejected` → REST for repo, `TartBackendError.scaleSetAuthRejected` (config error) for org. Tests first `RESTPollingDemandSourceTests`, `DemandSourceFactoryTests`.
7. **Status model** — `RunnerProcessState.onDemand(OnDemandState {booting, running, waitingForSlot})`; `.pulling` stays. Strings: "Waiting for jobs", "Booting for a queued job", "1 job running", "2 jobs running", "Waiting for a free VM slot". `RunnerDisplayStatus.swift`, `MenuBarMenuModel.swift`. Test first `RunnerDisplayStatusTests`.
8. **On-demand scheduler replaces slot loop** — remove `runSlot`, `runIteration`, iteration pacing (`minIterationDuration`/`restartDelay`), `maxConsecutiveRunnerFailures`. New `Services/Backends/OnDemandEntry.swift` per started runner: demand task + ≤2 `VMRun` tasks (6-hex id). Split `perform` into `prepare` (ensureImage + tarball), `bootVM` (in `bootGate`: count check, lease, clone, run, waitForGuest), `runJob` (JIT from source, `setJITRunnerID`, `runGuest`), existing `cleanUp`. Reconcile on demand update and VM exit: boot while `demand > live && live < 2`; budget full → `waitingForSlot`, re-check every 15 s and on any Ghast VM exit (backend-level notifier); on VM exit decrement cached demand until next fresh value. Transient errors → existing backoff (per VM run and demand loop); config errors → `finish(failure:)`. Stop/quit: cancel demand task, `source.close()`, `endGuestGracefully`/`cleanUp` all VMs incl. mid-boot. Inject `demandSourceFactory` (init + `AppDependencies`). Test first `TartBackendOnDemandTests` with `Mocks/FakeJobDemandSource.swift`: demand 0 → no clone; demand 2 → 2 VMs; two entries share budget; foreign darwin VM leaves 1; job finish → deleted, no replacement without demand; stop mid-boot → clone deleted, lease removed, close called; budget full → waitingForSlot. Adapt `TartBackendRetryTests`, `TartBackendStopTests`; recovery suite unchanged.
9. **Log prefixes** — `[vm a1b2c3] ` on lifecycle lines and guest/tart output; line-prefixing sink in `Services/Tart/` replacing raw handle at `RunnerLaunchSpec.appendOutputTo`. Tests: interleaved two-VM lines; sink buffers partial lines.
10. **Remove deletes scale set** — `RunnerRemover.remove` `.tart`: stop → `demandSourceFactory.make(for:).deleteRemote()` (404 ok; other failure → existing `.needsLocalOnlyConfirmation(reason:)`) → `removeFromThisMacOnly`. Test first `RunnerRemoverTests`.
11. **Migration, names, UI** — `LocalRunner.showsOnDemandNote` (true on decode for `.tart` without the key; dismiss → false, saved); labels kept encoded. New Runner sheet: hide `LabelTokenField` for Tart VM, add `runs-on: <name>` row with copy (reuse `tartNotice` pasteboard pattern). `RunnerConfigurationForm` VM section: drop Labels, add runs-on row. Output tab: dismissible note "Labels no longer apply. Use `runs-on: <name>`." `NewRunnerName`: VM names trimmed non-empty + existing rules. Tests first `LocalRunnerMigrationTests`, `NewRunnerNameTests`.
12. **Snapshots/fixtures** — states `vmWaitingForJobs`, `vmTwoJobs`, `vmWaitingForSlot`; flow `newRunnerTartRunsOn`; re-record existing VM snapshots (labels gone, runs-on row). Record, re-run green, commit PNGs. One `Scripts/fidelity/capture.sh new-runner` eyeball.
13. **Docs** — CLAUDE.md Runner Management: on-demand VMs, scale set / REST fallback, `runs-on: <name>`.

## Integration gate
1. `heavy xcodebuild test -project Ghast.xcodeproj -scheme Ghast -destination platform=macOS` (background).
2. `review.concurrency` on `git diff main...HEAD`; bar P0/P1 + anything start/stop/quit/remove can hit; budget/cleanup/session races.
3. Release (new-release skill); publish needs Evan's approval in the orchestrator session.
4. Evan live: repo and org runner each pick up a queued job; VM exists only while the job runs; fallback if the token is rejected.

## Risks
- Undocumented preview service (`api-version=6.0-preview`); shapes pinned to `716908e`.
- OAuth-minted registration token may be refused at runner-registration or scale-set create → `.authRejected` → REST (repo) / error (org).
- Stale stats: `totalAssignedJobs` and REST (15 s) lag; decrement heuristic covers the usual case; a miss boots one extra VM whose JIT runner idles until a job or Stop.
- Session 409 (same name on two Macs, crash leftover) → retried with backoff; shows "Waiting for jobs" + retry log lines.
- Scale-set JIT `runner.id` deleted via REST `deleteRunner`; if live 404s leave runners, fall back to `DELETE _apis/distributedtask/pools/0/agents/<id>` (`client.go` `RemoveRunner`, 204).
- No server name rules in the reference; a rejected name surfaces as a 400 config error on create.

## Decisions (orchestrator, 2026-11-18)
- Over-provisioned idle VM (demand drops below live VMs before a job starts): ship **without** scale-down; rely on the decrement heuristic. Add scale-down (via `JobStarted.runnerName` / guest "Running job" line) only if Evan sees idle VMs live.
