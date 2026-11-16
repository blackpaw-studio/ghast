import Foundation

/// The bash wrapper Ghast runs for each runner. It keeps `run.sh` going across the runner's
/// self-updates, timestamps every output line, and ends with the runner's own exit code.
///
/// Log format (one line each, ISO-8601 local time with offset):
///
///     2026-11-16T10:08:15-0500 ghast: start
///     2026-11-16T10:08:16-0500 √ Connected to GitHub
///     2026-11-16T10:30:00-0500 ghast: exit code=1
///
/// Exit 0 and 2 mean the runner is updating itself: the wrapper starts it again after
/// `restartDelay` seconds. Any other code ends the wrapper with that code.
enum RunnerWrapperScript {
    static let defaultRestartDelay = 5
    static let logFileName = "ghast-runner.log"

    static func make(runnerPath: String, logFile: String, parentPID: Int32, restartDelay: Int) -> String {
        """
        #!/bin/bash

        LOG_FILE=\(shellQuoted(logFile))
        RUNNER_DIR=\(shellQuoted(runnerPath))
        PARENT_PID=\(parentPID)
        RESTART_DELAY=\(max(0, restartDelay))

        log_line() {
            printf '%s %s\\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$LOG_FILE"
        }

        cd "$RUNNER_DIR" 2>/dev/null || {
            log_line "Error: cannot change to directory $RUNNER_DIR"
            log_line "ghast: exit code=1"
            exit 1
        }

        if [ ! -f ./run.sh ]; then
            log_line "Error: ./run.sh not found in $RUNNER_DIR"
            log_line "ghast: exit code=127"
            exit 127
        fi
        [ -x ./run.sh ] || chmod +x ./run.sh

        while true; do
            log_line "ghast: start"
            # A pipeline, not a process substitution, so every output line is logged before the
            # exit marker below.
            ./run.sh < /dev/null 2>&1 | while IFS= read -r line || [ -n "$line" ]; do
                log_line "$line"
            done
            EXIT_CODE=${PIPESTATUS[0]}
            log_line "ghast: exit code=$EXIT_CODE"

            # Don't outlive Ghast.
            if ! kill -0 "$PARENT_PID" 2>/dev/null; then
                break
            fi
            if [ "$EXIT_CODE" -eq 0 ] || [ "$EXIT_CODE" -eq 2 ]; then
                sleep "$RESTART_DELAY"
            else
                break
            fi
        done
        exit "$EXIT_CODE"
        """
    }

    /// `value` as one single-quoted bash word, so a runner folder name can never be syntax.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
