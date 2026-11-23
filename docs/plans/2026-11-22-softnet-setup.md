# Plan: Network isolation setup (softnet helper)

Spec: `docs/specs/2026-11-22-softnet-setup.md` (wins on conflict). It extends `2026-11-19-tart-vm-resources.md`. Branch `feat/tart-vm-resources`, base commit `2cd2232`.
`T <Suite>` = `xcodebuild test -project Ghast.xcodeproj -scheme Ghast -destination platform=macOS PRODUCT_BUNDLE_IDENTIFIER=net.evancoleman.ghast.devtest -only-testing:GhastTests/<Suite>`. The installed Ghast blocks the default test host, so every xcodebuild call needs the devtest ID. Run `xcodegen` after adding files. Commit after each step with an emoji prefix.

## Decisions the spec left open
The orchestrator accepted all five on 2026-11-22. Decision 1 is folded into the spec's readiness check and setup text.
1. **Where to find the source softnet.** A GUI app's inherited `PATH` is launchd's `/usr/bin:/bin:/usr/sbin:/sbin`. It never holds Homebrew, so "softnet on the inherited PATH" would always be `softnetMissing`. Proposal: search `TartLocator.knownPaths`' folders (`/opt/homebrew/bin`, `/usr/local/bin`) first, then the inherited `PATH`, always skipping `/usr/local/libexec/ghast`. This is the same rule Ghast uses to find `tart`. Update the spec's "Finding it" section to match.
2. **When the status row shows.** Show it only while "Isolate network" is on. With the toggle off, the status doesn't matter.
3. **Outdated log line.** Log it once per started runner, not once per boot: `Softnet was updated; open Configuration and choose Update… to refresh the isolation helper`.
4. **Helper whose `--version` doesn't run** (safe file, but no output or a non-zero exit) maps to `unsafe(.doesNotRun)`, not `outdated`.
5. **Re-check after a block.** A blocked entry is checked again on the next demand report from its source, or when `SoftnetHelperModel` reports a status change. The log line and the error state stay until a boot passes the gate, so they don't flicker on each re-check.

## Step 1: spike on Dionysus (gates steps 2–5)
**1a. Install script (written by the implementer, run by Evan).** Add `Ghast/Resources/install-softnet-helper.sh` (commit `🔧 Softnet helper install script`). Production passes this same text to `/bin/sh -c` with root rights, so the spike tests exactly what ships. Usage: `install-softnet-helper.sh SOURCE TARGET_DIR`. The script does, in order:
- `set -eu`, `umask 022`, full paths for every tool. Exactly 2 args, else exit 64.
- `TARGET_DIR` must equal `/usr/local/libexec/ghast`, else exit 64 (`unexpected target`). It checks this before checking root.
- `id -u` must be 0, else exit 77.
- `real=$(/usr/bin/realpath "$SOURCE")` follows symlinks. The result must be a regular executable file, else exit 66.
- `mkdir -p` the target, then `chown root:wheel` and `chmod 0755`.
- Each of `/usr/local/libexec/ghast /usr/local/libexec /usr/local /usr /` must be a real directory (not a symlink), uid 0, with `(mode & 022) == 0`, else exit 73 (`unsafe folder: <p>`). It never chowns a folder it didn't create.
- `tmp=$(mktemp "$dir/.softnet.XXXXXX")`, with a trap that removes it on exit. Then `cp "$real" "$tmp"`.
- If 1b check 3 finds a team signature: `codesign --verify --strict -R='<requirement>' "$tmp"`, else exit 75. This verifies the root-owned copy, which the user can't swap.
- `chown root:wheel "$tmp"`, then `chmod 4755` (chown clears setuid, so this order matters). Then `mv -f "$tmp" "$dir/softnet"` as an atomic rename, and clear the trap.

Evan runs this himself: `sudo /bin/sh Ghast/Resources/install-softnet-helper.sh "$(command -v softnet)" /usr/local/libexec/ghast`. He's on another machine, so he can do it over SSH.

**1b. Non-root checks (implementer, as `evan`).** Stop every VM runner first. `tart list` must show no running macOS VM. Set `MINPATH=/usr/bin:/bin:/usr/sbin:/sbin`, which is what Ghast inherits.
1. `stat -f '%Su:%Sg %Sp' /usr/local/libexec/ghast/softnet /usr/local/libexec/ghast /usr/local/libexec`. Expect `root:wheel -rwsr-xr-x`, then `drwxr-xr-x` owned by root.
2. `/usr/local/libexec/ghast/softnet --version` and `/opt/homebrew/bin/softnet --version`. Record the exact output and whether they're equal.
3. `codesign -dv --verbose=2 "$(realpath /opt/homebrew/bin/softnet)"`. Record Authority, TeamIdentifier and flags (adhoc or not).
4. `tart clone "$IMAGE" ghast-sn1`, then in the background: `env -i HOME="$HOME" USER="$USER" PATH=/usr/local/libexec/ghast:$MINPATH /opt/homebrew/bin/tart run --no-graphics --net-softnet --dir=ghast:$SCRATCH/s1:ro --dir=ghast-job:$SCRATCH/s2:ro ghast-sn1`. Loop on `tart exec ghast-sn1 true` until it answers. Record whether it prompted or printed a sudo error.
5. `ls` both shares. `curl -sS -o /dev/null -w '%{http_code}' https://github.com` should succeed. `curl -m 5` to `10.0.2.10`, `10.0.4.10` and `$(ipconfig getifaddr en0)` should all fail (non-zero exit). Record `tart ip ghast-sn1`.
6. Boot a second clone `ghast-sn2` the same way. From it, `curl -m 5` and `ping -c 2 -t 5` to sn1's IP should both fail.
7. Control: run check 4 with `PATH=$MINPATH` only. Record the error (expected: softnet not found or root required). This shows the `PATH` entry is what makes isolation work.
8. Stop and delete both clones. Leave the helper installed. Record everything in a `## Step 0 results` section of the spec and commit `📝 Spec: softnet spike results`.

| Result | Change |
|---|---|
| Check 5: LAN reachable | Step 4's `TartArguments.run` adds `--net-softnet-block=<cidr>` for 10/8, 172.16/12, 192.168/16 and 169.254/16. Read the flag syntax and whether it repeats from `tart run --help`. Leave out the vmnet gateway subnet (from `tart ip`) if a block cuts DNS. Re-run checks 5–6 with the flags. The exact argv goes into the step 4 tests. |
| Check 3: unsigned or ad hoc | No signature check. Record it in the spec and PR body as an accepted risk: setup trusts the user-owned binary at the moment the admin approves. |
| Check 3: signed by a team | Step 2 adds `SoftnetHelperScripts.signingRequirement` and the step 1a `codesign` line, plus a test that the script text contains the requirement. |
| Check 4 prompts or fails, or Tart still asks for sudo | Stop and escalate: the design doesn't hold. |
| Check 2: no `--version` | Stop and escalate. Proposed fix: compare SHA-256 hashes instead. |
| Check 6: second VM reaches the first | Stop and escalate. The spec doesn't cover this. |

## Steps (TDD, one commit each)

**2. Scripts and paths.** New `Ghast/Services/Softnet/SoftnetHelperScripts.swift`:
- `static let helperDirectory = "/usr/local/libexec/ghast"` and `helperPath`.
- `static func installScript(bundle: Bundle = .main) throws -> String` reads the resource.
- `static let removeScript`: `/bin/rm -f /usr/local/libexec/ghast/softnet; /bin/rmdir /usr/local/libexec/ghast 2>/dev/null; exit 0`. It's a constant and takes no args.
- After the build, confirm the `.sh` is in `Ghast.app/Contents/Resources`. If it isn't, add `buildPhase: resources` for it in `project.yml`.

Tests first, new `SoftnetHelperScriptTests`. Each one runs the bundled text through `/bin/sh -c <text> sh <args>` as a normal user:
- `"the install script refuses any other target"`: target `/tmp/x` → status 64, output contains `unexpected target`.
- `"the install script refuses to run without root"`: the correct target → 77, and nothing is created.
- `"the install script needs exactly two arguments"` → 64.
- `"removal touches only the helper path"`: every absolute path in `removeScript` is in `{helperPath, helperDirectory, "/bin/rm", "/bin/rmdir"}`.

Verify: `T SoftnetHelperScriptTests`.

**3. Readiness check (pure logic).** New files in `Ghast/Services/Softnet/`:
- `SoftnetHelperStatus` is `Equatable, Sendable`: `.notInstalled`, `.unsafe(UnsafeReason)`, `.outdated(installed:available:)`, `.ready(version:)`, `.softnetMissing`.
- `UnsafeReason` is `.symlink`, `.notRegularFile`, `.notOwnedByRoot`, `.notSetuid`, `.writableByOthers`, `.unsafeFolder(String)`, `.doesNotRun`. Each has a user-facing `message`.
- `var setupRow: (text: String, action: SetupAction?)?` gives the spec's copy: `Set Up…` for notInstalled and unsafe, `Update…` for outdated, no button for softnetMissing, nil for ready. `settingsText` covers the General row.
- `protocol FileInspecting: Sendable { func entry(atPath:) -> FileEntry? }`. `FileEntry` holds `kind` (`.file`/`.directory`/`.symlink`/`.other`), `ownerID` and `mode`. `SystemFileInspector` uses `lstat`, which never follows links.
- `protocol SoftnetVersionReading: Sendable { func version(of: URL) async -> String? }`. `ProcessSoftnetVersionReader` runs `--version` through `ProcessRun` and returns the trimmed output, or nil on a non-zero exit.
- `struct SoftnetHelperChecker: SoftnetHelperChecking` has `func status() async -> SoftnetHelperStatus` and `func locateSource() -> URL?`. Search order is decision 1. The inherited `PATH` is injected (default `ProcessInfo`). Helper rules:
  - No entry → `softnetMissing` if there's no source, else `notInstalled`.
  - symlink → `.symlink`; not a file → `.notRegularFile`; uid ≠ 0 → `.notOwnedByRoot`; no `S_ISUID` → `.notSetuid`; `mode & 022` → `.writableByOthers`.
  - Each parent up to `/` that isn't a root-owned, non-symlink directory with no 022 bits → `.unsafeFolder(path)`.
  - Then compare versions. With no source, a safe helper is `ready`.
- Fakes in `GhastTests/Mocks/`: `FakeFileInspector` (a dictionary of path → entry) and `FakeSoftnetVersions`.

Tests first, new `SoftnetHelperStatusTests`, against a safe tree plus one change per case:
- `"no helper and no softnet"` → `.softnetMissing`; `"no helper"` → `.notInstalled`.
- `"a symlinked helper is unsafe"` → `.unsafe(.symlink)`, and the version reader is never called.
- Parameterised: owner 501 → `.notOwnedByRoot`; mode 0755 → `.notSetuid`; mode 04775 → `.writableByOthers`.
- `"a group-writable parent is unsafe"`: `/usr/local/libexec` at 0775 → `.unsafeFolder("/usr/local/libexec")`.
- `"versions differ"` → `.outdated(installed: "0.25.0", available: "0.26.0")`; equal → `.ready("0.26.0")`; helper reads nil → `.unsafe(.doesNotRun)`.
- `"the source search skips the helper folder"`: `PATH` = helper dir only → `locateSource() == nil`.
- `"each status maps to its row"`: exact text and action for each status.
- `"the system inspector does not follow symlinks"`: a real temp symlink → `.symlink`.

Verify: `T SoftnetHelperStatusTests`.

**4. Launch environment and argv.**
- `RunnerLaunchSpec` gains `environment: [String: String]? = nil` (nil inherits). `ProcessRunnerLauncher.start` sets `process.environment` when it isn't nil.
- New `enum TartNetwork: Equatable, Sendable { case shared, softnet(helperDirectory: String) }`. It replaces `isNetworkIsolated: Bool` in `TartArguments.run`, `TartCLI.run`, `ProcessTartCLI.run` and `FakeTartCLI.run`. An isolated boot can't be built without the helper folder.
- `ProcessTartCLI` init gains `baseEnvironment: [String: String] = ProcessInfo.processInfo.environment`. For `.softnet(dir)`, `PATH = dir + ":" + (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")` and every other key is kept. For `.shared`, `environment` is nil.
- The fake keeps logging ` softnet` for `.softnet` and records the last `network`.

Tests first:
- `ProcessTartCLITests`: `"an isolated run puts the helper folder first on PATH"` → `spec.environment?["PATH"] == "/usr/local/libexec/ghast:/usr/bin:/bin"`, `HOME` kept, argv contains `--net-softnet`.
- `ProcessTartCLITests`: `"a shared run inherits the environment unchanged"` → `spec.environment == nil`, no `--net-softnet`.
- `TartCLIParsingTests` updated to `.shared` and `.softnet(...)`, with exact argv, plus block flags if step 1 needs them.

Verify: `T ProcessTartCLITests`, `T TartCLIParsingTests`.

**5. Backend gate.**
- `TartBackend.init` gains `softnet: any SoftnetHelperChecking`. `unavailable` passes a fake that returns `.notInstalled`.
- In `bootAndRun`, after `cliProvider` and before `prepare`, if `runner.vmResources.isNetworkIsolated`:
  - `ready` or `outdated` → `network = .softnet(helperDirectory)`. `outdated` logs decision 3's line once per entry (`entry.hasLoggedOutdatedHelper`).
  - Anything else → return a new `VMOutcome.isolationNotReady`. There's no pull, no slot and no clone.
- `finished(.isolationNotReady)`: remove the VM. If `!entry.isolationNotReady`, log `Network isolation isn't set up on this Mac; open Configuration to set it up`. Then set `entry.isolationNotReady = true` and `entry.mayRecheckIsolation = false`, and publish. No sleep, no failure count, no reconcile loop.
- `reconcile` launches nothing while `isolationNotReady && !mayRecheckIsolation`.
- `demandChanged` sets `mayRecheckIsolation = true`. A boot that passes the gate (isolated and ready, or not isolated) clears `isolationNotReady`.
- New `func softnetStatusChanged()` sets `mayRecheckIsolation` on every entry and reconciles.
- `OnDemandState` gains `needsIsolationSetup`. `OnDemandPhase` gains `.needsIsolationSetup` ("Network isolation isn't set up", error styling). It ranks after `running` and before `booting`, so a re-check doesn't flicker.
- `TartHarness` takes a `FakeSoftnetChecker` (default `.ready("0.26.0")`, counts calls), so the existing isolation tests keep passing.

Tests first, new `TartBackendIsolationTests`:
- `"an isolated boot with a ready helper runs tart with the helper folder"` → `cli.lastNetwork == .softnet(helperDirectory: "/usr/local/libexec/ghast")`.
- `"a non-isolated boot never checks the helper"` → 0 checks, `.shared`.
- `"isolation not set up: no clone, one log line, no retry"`, parameterised over notInstalled, unsafe and softnetMissing → no `clone`/`pull` in `h.log`, the exact line once, `h.sleeps` empty, 1 check. A repeated demand report → 2 checks, still one line, still no clone.
- `"outdated boots with the installed helper and logs once"`: two jobs → 2 `run … softnet`, one line.
- `"a status change lets a blocked runner boot"`: switch the fake to `.ready`, call `softnetStatusChanged()` → `clone` happens and `needsIsolationSetup` is false.
- `RunnerDisplayStatusTests`: `"a runner blocked on isolation says so"` → `.needsIsolationSetup` with its title.

Verify: `T TartBackendIsolationTests`, `T TartBackendResourcesTests`, `T TartBackendTests`, `T RunnerDisplayStatusTests`.

**6. Privileged runner and the helper model.**
- `protocol PrivilegedScriptRunning: Sendable { func run(script: String, arguments: [String]) async throws(PrivilegedScriptError) }`, with errors `.cancelled` and `.failed(String)`.
- `AppleScriptPrivilegedRunner` (`@MainActor`) has one constant handler: `on runPrivileged(scriptText, args)` builds `"/bin/sh -c " & quoted form of scriptText & " ghast-softnet"`, appends `" " & quoted form of a` for each arg, then runs `do shell script … with administrator privileges`. It calls the handler through `NSAppleScript.executeAppleEvent` with a `kASSubroutineEvent` descriptor (`keyASSubroutineName` = "runprivileged"; script text and args go in as a list descriptor). No value is ever put into the script source. Error -128 → `.cancelled`, any other error → `.failed(NSAppleScriptErrorMessage)`.
- `@MainActor @Observable final class SoftnetHelperModel(checker:runner:installScript:onStatusChange:)` has `status`, `isWorking`, `errorMessage`, `refresh()`, `setUp()` and `remove()`.
  - `setUp` takes `checker.locateSource()`. If there's none, the status becomes `softnetMissing`. Otherwise it runs `runner.run(script: installScript, arguments: [source.path, helperDirectory])`.
  - `remove` runs `runner.run(script: removeScript, arguments: [])`.
  - On success or `.failed`, it re-checks. `.failed` also sets `errorMessage`. On `.cancelled`, nothing changes.
  - It calls `onStatusChange` when the status differs.
- `FakePrivilegedRunner` records calls and returns a scripted result.

Tests first, new `SoftnetHelperSetupTests`:
- `"setup passes the script and quoted arguments separately"` → recorded script `== installScript` and doesn't contain the source path; args `== [source, "/usr/local/libexec/ghast"]`; status re-checked to `.ready`.
- `"a cancelled prompt leaves the status as it was"` → status still `.notInstalled`, `errorMessage == nil`, no `onStatusChange`.
- `"a failed script shows its message and re-checks"`.
- `"removal runs the fixed rm script with no arguments"`.
- `"the privileged handler compiles"` → `NSAppleScript(source:).compileAndReturnError` succeeds, and no event is sent.

Verify: `T SoftnetHelperSetupTests`.

**7. Wiring and fixture.**
- `AppDependencies.live` builds one `SoftnetHelperChecker` and gives it to `TartBackend` and to `SoftnetHelperModel`, whose `onStatusChange` calls `tartBackend.softnetStatusChanged()`. The model goes into the environment of the main window and the Settings window.
- Fixture: `FixtureSoftnetHelper.swift` has a fixed-status checker (default `.ready("0.26.0")`) and a runner that throws `.cancelled` without prompting.
- `FixtureSafetyTests`: `"fixture mode never runs a privileged script"`.

Verify: `xcodebuild build … PRODUCT_BUNDLE_IDENTIFIER=net.evancoleman.ghast.devtest`, then `T FixtureSafetyTests`.

**8. UI** (no TDD for styling; snapshots in step 9 cover it, and the copy comes from the step 3 tests).
- `RunnerConfigurationForm.resourcesSection`: below the toggle, while it's on and `setupRow != nil`, a `FocusFormRow` with the status text and its button. The button is disabled while `isWorking`. `errorMessage` shows in red below the row. `.task { await model.refresh() }` when the tab appears.
- New `resourcesHelp`: "A disk only grows, never shrinks. Isolating the network blocks this Mac's local network from VMs and keeps internet access; setup asks once for an administrator password."
- `GeneralSettingsView`: a new section "VM network isolation" with a row showing `settingsText`. `Remove Helper…` appears when a helper file exists (ready, outdated or unsafe). It sits behind `.confirmationDialog("Remove the network isolation helper?")` with the message "Runners with Isolate network on can't start VMs until you set it up again." The pane refreshes in its `.task`.

Verify: build.

**9. Snapshots.**
- `FocusMainSnapshotTests` gets three new isolated states on the configuration tab: `vmIsolationSetup` (notInstalled), `vmIsolationUnsafe` (`.unsafeFolder("/usr/local/libexec")`) and `vmIsolationOutdated`. Add them to `isVM` and the `.configuration` mapping. `vmConfiguration` stays `.ready`, so no row shows. Only its help line changes, so re-record it.
- `FocusSettingsSnapshotTests.general` is re-recorded with the new row.
- Record with `TEST_RUNNER_SNAPSHOT_RECORD_MODE=true xcodebuild test … PRODUCT_BUNDLE_IDENTIFIER=net.evancoleman.ghast.devtest -only-testing:GhastTests/FocusMainSnapshotTests -only-testing:GhastTests/FocusSettingsSnapshotTests`. Re-run without the variable to confirm green, look at the new PNGs at native size (light and dark), and commit `GhastTests/__Snapshots__/`.

Verify: `T FocusMainSnapshotTests`, `T FocusSettingsSnapshotTests`.

**10. Docs.**
- In `CLAUDE.md`, replace the sentence "Isolation adds `--net-softnet` and fails closed: … never falling back to an unisolated VM." with this: isolation runs `tart run --net-softnet` with `PATH=/usr/local/libexec/ghast:<inherited>`. The helper there is a root-owned setuid copy of softnet, installed by `Ghast/Resources/install-softnet-helper.sh` through `NSAppleScript` with administrator privileges (injected `PrivilegedScriptRunning`). Readiness comes from `SoftnetHelperChecker` (injected `FileInspecting` and `SoftnetVersionReading`). If it isn't ready, Ghast doesn't clone, logs one line, shows `needsIsolationSetup`, and checks again on the next demand. Remove is in Settings › General.
- Add the three new states to the snapshot list.
- Spec status → implemented.

## Integration gate
1. In the background: `heavy xcodebuild test -project Ghast.xcodeproj -scheme Ghast -destination platform=macOS PRODUCT_BUNDLE_IDENTIFIER=net.evancoleman.ghast.devtest`.
2. `review.security` on `git diff 2cd2232...HEAD`. Bar: P0/P1, plus anything that lets a same-user process get root or boot an unisolated VM when isolation is on, or anything a real setup, cancel, remove or boot can hit.
3. Live check on Dionysus with a Debug build. Evan needs Screen Sharing to type the password.
   1. Remove the spike's helper with Settings › Remove Helper…, and confirm the file is gone.
   2. Queue a job on an isolated VM runner → one log line, no `ghast-*` clone in `tart list`, error state shown.
   3. Configuration → Set Up…, then cancel the prompt → status unchanged.
   4. Set Up… again and enter the password → `ready`, and the blocked runner boots without needing a new job.
   5. In the job: `curl https://github.com` works, `curl -m 5 http://10.0.2.10` fails, checkout works.
   6. Turn isolation off → the next job boots without softnet.

## Risks
- **Trust window.** Setup copies a user-owned binary. With no signature check (step 1), a process already running as the user can swap it before the admin approves. The spec accepts this; the PR body records it.
- **Existing user-owned `/usr/local/libexec`** (left by an Intel Homebrew install): the script exits 73 and the status is `unsafe(.unsafeFolder)`. Ghast never chowns the folder. The message names the folder, and the user fixes it by hand.
- **`NSAppleScript` runs on the main actor**, so the UI is frozen while the password prompt is up and during the copy. If that's not acceptable, the alternative is `osascript` with a constant `on run argv` script, which still passes the args as argv.
- **No timeout on `--version` and the readiness check.** `ProcessRun` has none, so a hung softnet stalls that boot.
- **Running the setuid helper with `--version`** briefly runs it as root.
- **Outdated detection compares version strings only.** A Homebrew rebuild that keeps the version number isn't detected.
- **Hardened runtime.** In-process `do shell script` should need no Apple Events entitlement. The live check confirms it, since a TCC prompt or refusal shows there.
