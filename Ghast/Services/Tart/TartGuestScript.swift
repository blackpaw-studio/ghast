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

    /// Run it as `/bin/bash -c <script> _ <encoded jit config>`. Output lines are timestamped
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
        if [ -f "$JOB/\(VMJobFiles.environmentFile)" ]; then cat "$JOB/\(VMJobFiles.environmentFile)" >> .env || exit 1; fi
        \(hook(VMJobFiles.preJobScript, variable: "ACTIONS_RUNNER_HOOK_JOB_STARTED"))
        \(hook(VMJobFiles.postJobScript, variable: "ACTIONS_RUNNER_HOOK_JOB_COMPLETED"))
        ./run.sh --jitconfig "$1" < /dev/null 2>&1 | while IFS= read -r line || [ -n "$line" ]; do
            printf '%s %s\\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$line"
        done
        exit "${PIPESTATUS[0]}"
        """
    }

    /// Copies a job script in and points the runner's hook at it, when the share has it.
    private static func hook(_ file: String, variable: String) -> String {
        """
        if [ -f "$JOB/\(file)" ]; then
            cp "$JOB/\(file)" \(file) && chmod +x \(file) || exit 1
            echo "\(variable)=$PWD/\(file)" >> .env
        fi
        """
    }

    /// The argv `tart exec` runs for `tarball` and `jitConfig`.
    static func command(tarball: String, jitConfig: String) -> [String] {
        ["/bin/bash", "-c", make(tarball: tarball), "_", jitConfig]
    }
}
