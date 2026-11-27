import Foundation

/// The bash a VM runner's guest executes: extract the shared runner package, copy in the job
/// share's scripts and variables (`VMJobFiles`), and run it with a JIT config. The config
/// arrives as `$1`, never inside the script text; variable values only ever sit in files.
enum TartGuestScript {
    static let shareName = "ghast"
    /// Where a macOS guest sees the share named `ghast`.
    static let sharePath = "/Volumes/My Shared Files/\(shareName)"
    /// How long the guest waits for the share to appear before giving up.
    static let shareWaitSeconds = 30

    /// Run it as `/bin/bash -c <script> _ <encoded jit config> [<cache URL>]`. Output lines are timestamped
    /// in the log format; the script ends with `run.sh`'s exit code.
    static func make(tarball: String) -> String {
        let archive = RunnerWrapperScript.shellQuoted("\(sharePath)/\(tarball)")
        let job = RunnerWrapperScript.shellQuoted(VMJobFiles.sharePath)
        return """
        ARCHIVE=\(archive)
        JOB=\(job)
        WAITED=0
        while [ ! -f "$ARCHIVE" ] && [ "$WAITED" -lt \(shareWaitSeconds) ]; do
            sleep 1
            WAITED=$((WAITED + 1))
        done
        if [ ! -f "$ARCHIVE" ]; then
            echo "Error: runner package not found at $ARCHIVE"
            exit 1
        fi
        [ -d "$JOB" ] || { echo "Error: job share missing at $JOB" >&2; exit 1; }
        mkdir -p "$HOME/actions-runner" && cd "$HOME/actions-runner" || exit 1
        tar xzf "$ARCHIVE" || { echo "Error: could not extract the runner package"; exit 1; }
        \(cacheBlock)
        if [ -f "$JOB/\(VMJobFiles.environmentFile)" ]; then cat "$JOB/\(VMJobFiles.environmentFile)" >> .env || exit 1; fi
        \(jobStartedBlock)
        \(hook(VMJobFiles.postJobScript, variable: "ACTIONS_RUNNER_HOOK_JOB_COMPLETED"))
        \(runBlock)
        """
    }

    static let hookFile = "ghast-job-started.sh"
    /// Where the hook leaves the run's identity for the watcher.
    static let runInfoFile = ".ghast-run-info"

    /// Ghast's own job-started hook, run by the runner exactly as it ran `pre-job.sh` before
    /// (same shell, same options, same environment). It records the run's repository, workflow,
    /// run id and attempt (base64, one line, written aside and renamed), drops its own names,
    /// then sources the user's pre-job script when there is one, so that script's `exit` or
    /// failing command still decides the hook's status. Ghast's writes can't fail the job. The
    /// hook's stdout goes to the job log, so it prints nothing; `runBlock` reports the file.
    /// Each value is clipped to 200 characters before it is encoded, so the whole line stays
    /// far under the 4 KB `runBlock` reads (a longer name would cut off the run id).
    static let jobStartedHook = #"""
    #!/bin/bash
    # Managed by Ghast - do not edit manually
    ghast_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    {
        ghast_b64() { printf '%s' "${1:0:200}" | /usr/bin/base64 | tr -d '\n'; }
        ghast_tmp="$HOME/\#(runInfoFile).$$"
        printf 'repository=%s workflow=%s run_id=%s run_attempt=%s\n' \
            "$(ghast_b64 "$GITHUB_REPOSITORY")" "$(ghast_b64 "$GITHUB_WORKFLOW")" \
            "$(ghast_b64 "$GITHUB_RUN_ID")" "$(ghast_b64 "$GITHUB_RUN_ATTEMPT")" > "$ghast_tmp" \
            && mv -f "$ghast_tmp" "$HOME/\#(runInfoFile)"
        rm -f "$ghast_tmp"
    } >/dev/null 2>&1 || true
    unset -f ghast_b64
    unset ghast_tmp
    if [ -f "$ghast_dir/\#(VMJobFiles.preJobScript)" ]; then
        unset ghast_dir
        . "$(dirname "${BASH_SOURCE[0]}")/\#(VMJobFiles.preJobScript)"
    fi
    """#

    /// Writes Ghast's hook, copies the user's pre-job script beside it (when the share has
    /// one) and points the runner's started hook at Ghast's.
    private static var jobStartedBlock: String {
        """
        cat > \(hookFile) <<'GHAST_HOOK_EOF' || exit 1
        \(jobStartedHook)
        GHAST_HOOK_EOF
        chmod +x \(hookFile) || exit 1
        if [ -f "$JOB/\(VMJobFiles.preJobScript)" ]; then
            cp "$JOB/\(VMJobFiles.preJobScript)" \(VMJobFiles.preJobScript) && chmod +x \(VMJobFiles.preJobScript) || exit 1
        fi
        echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=$PWD/\(hookFile)" >> .env
        """
    }

    /// Runs the runner and reports the run info. A background watcher waits for the hook's
    /// file, prints one marker line (`<stamp> ghast: run-info <line>`, first 4 KB of the first
    /// line only) and exits. After `run.sh` the watcher is killed and awaited; if it was
    /// killed before it printed (a run that ended between two polls) the file is read once
    /// more and reported. A watcher that finished has printed, so a line never appears twice.
    /// The watcher's `sleep` writes nowhere and the script exits with `run.sh`'s status, so
    /// nothing keeps the exec stream open.
    static let runBlock = #"""
    ghast_report() {
        GHAST_INFO="$(head -c 4096 "$HOME/\#(runInfoFile)" 2>/dev/null | head -n 1)"
        printf '%s ghast: run-info %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$GHAST_INFO"
    }
    rm -f "$HOME/\#(runInfoFile)"
    (
        while [ ! -f "$HOME/\#(runInfoFile)" ]; do sleep 0.5 >/dev/null 2>&1 </dev/null; done
        ghast_report
    ) &
    GHAST_WATCHER=$!
    ./run.sh --jitconfig "$1" < /dev/null 2>&1 | while IFS= read -r line || [ -n "$line" ]; do
        printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$line"
    done
    GHAST_STATUS="${PIPESTATUS[0]}"
    kill "$GHAST_WATCHER" >/dev/null 2>&1
    { wait "$GHAST_WATCHER"; } >/dev/null 2>&1
    if [ "$?" != 0 ] && [ -f "$HOME/\#(runInfoFile)" ]; then ghast_report; fi
    exit "$GHAST_STATUS"
    """#

    /// Copies a job script in and points the runner's hook at it, when the share has it.
    private static func hook(_ file: String, variable: String) -> String {
        """
        if [ -f "$JOB/\(file)" ]; then
            cp "$JOB/\(file)" \(file) && chmod +x \(file) || exit 1
            echo "\(variable)=$PWD/\(file)" >> .env
        fi
        """
    }

    /// Points the runner at Ghast's cache when `$2` (the cache URL) is set. The runner
    /// overwrites `ACTIONS_RESULTS_URL` at every job, so its one UTF-16LE copy in
    /// `bin/Runner.Worker.dll` is renamed to `ACTIONS_RESULTS_ORL` (same length) and the URL
    /// goes in `.env`. The patch is made on a copy, the URL written, and only then is the copy
    /// moved over the DLL, so the two always change together. Anything unexpected (no copy,
    /// several, a patch that didn't take, an unwritable `.env`) leaves the original DLL and
    /// `.env` alone with one log line, and the job uses GitHub's cache.
    static let cacheBlock = #"""
    if [ -n "$2" ]; then
        DLL=bin/Runner.Worker.dll
        GHAST_PATCHED="$DLL.ghast-patch"
        ghast_count() { GHAST_NEEDLE="$1" perl -0777 -ne 'my $n = join("", map { $_ . "\0" } split(//, $ENV{GHAST_NEEDLE})); my $c = () = /\Q$n\E/g; print $c' "$2" 2>/dev/null; }
        ghast_off() { rm -f "$GHAST_PATCHED"; echo "Local cache off: $1; this job uses GitHub's cache"; }
        GHAST_FOUND=$(ghast_count ACTIONS_RESULTS_URL "$DLL")
        GHAST_ENV_SIZE=$( { [ -f .env ] && wc -c < .env; } 2>/dev/null || echo 0)
        if [ "$GHAST_FOUND" != "1" ]; then
            ghast_off "the runner has ${GHAST_FOUND:-0} copies of its results URL setting, not 1"
        elif ! cp -p "$DLL" "$GHAST_PATCHED" 2>/dev/null \
            || ! perl -0777 -pi -e 'my $f = join("", map { $_ . "\0" } split(//, "ACTIONS_RESULTS_URL")); my $t = join("", map { $_ . "\0" } split(//, "ACTIONS_RESULTS_ORL")); s/\Q$f\E/$t/' "$GHAST_PATCHED" 2>/dev/null \
            || [ "$(ghast_count ACTIONS_RESULTS_URL "$GHAST_PATCHED")" != "0" ]; then
            ghast_off "the runner patch didn't apply"
        elif ! printf 'ACTIONS_RESULTS_URL=%s\n' "$2" 2>/dev/null >> .env; then
            ghast_off "couldn't write the cache URL to .env"
        elif ! mv -f "$GHAST_PATCHED" "$DLL" 2>/dev/null; then
            perl -e 'truncate(".env", $ARGV[0])' "$GHAST_ENV_SIZE" 2>/dev/null
            ghast_off "couldn't install the patched runner"
        fi
    fi
    """#

    /// The argv `tart exec` runs for `tarball` and `jitConfig`; `cacheURL`, when set, is `$2`.
    static func command(tarball: String, jitConfig: String, cacheURL: URL? = nil) -> [String] {
        ["/bin/bash", "-c", make(tarball: tarball), "_", jitConfig] + (cacheURL.map { [$0.absoluteString] } ?? [])
    }
}
