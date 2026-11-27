import Testing
import Foundation
@testable import Ghast

@Suite("Tart guest script")
struct TartGuestScriptTests {
    @Test("extracts the shared package and runs it with the JIT config passed as $1")
    func script() {
        let script = TartGuestScript.make(tarball: "actions-runner-osx-arm64-2.329.0.tar.gz")

        #expect(script.contains("'/Volumes/My Shared Files/ghast/actions-runner-osx-arm64-2.329.0.tar.gz'"))
        #expect(script.contains(#"./run.sh --jitconfig "$1""#))
        #expect(script.contains(#"GHAST_STATUS="${PIPESTATUS[0]}""#))
        #expect(script.contains(#"exit "$GHAST_STATUS""#))
    }

    @Test("the JIT config rides in argv, never in the script text")
    func configStaysOutOfScript() {
        let command = TartGuestScript.command(tarball: "r.tar.gz", jitConfig: "SECRET-CONFIG")

        #expect(command.prefix(2) == ["/bin/bash", "-c"])
        #expect(!command[2].contains("SECRET-CONFIG"))
        #expect(command.suffix(2) == ["_", "SECRET-CONFIG"])
    }

    @Test("a file name with quotes cannot break out of its word")
    func quoting() {
        let script = TartGuestScript.make(tarball: "a'b.tar.gz")

        #expect(script.contains(#"'/Volumes/My Shared Files/ghast/a'\''b.tar.gz'"#))
    }

    @Test("before run.sh, copies the job share's scripts and variables in, with a hook only for a script that is there")
    func jobFiles() throws {
        let script = TartGuestScript.make(tarball: "r.tar.gz")

        #expect(script.contains("JOB='/Volumes/My Shared Files/ghast-job'"))
        #expect(script.contains(#"if [ -f "$JOB/.env" ]; then cat "$JOB/.env" >> .env || exit 1; fi"#))
        #expect(script.contains("""
        if [ -f "$JOB/post-job.sh" ]; then
            cp "$JOB/post-job.sh" post-job.sh && chmod +x post-job.sh || exit 1
            echo "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=$PWD/post-job.sh" >> .env
        fi
        """))
        // The started hook is always Ghast's own; the user's pre-job script is copied beside it and sourced by it.
        #expect(script.contains(#"cp "$JOB/pre-job.sh" pre-job.sh && chmod +x pre-job.sh || exit 1"#))
        #expect(script.contains(#"echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=$PWD/ghast-job-started.sh" >> .env"#))
        #expect(!script.contains(#"ACTIONS_RUNNER_HOOK_JOB_STARTED=$PWD/pre-job.sh"#))
        let copy = try #require(script.range(of: "$JOB/.env"))
        let extract = try #require(script.range(of: "tar xzf"))
        let run = try #require(script.range(of: "./run.sh"))
        #expect(extract.lowerBound < copy.lowerBound && copy.lowerBound < run.lowerBound)
    }

    @Test("a missing job share fails the run loudly instead of running without scripts")
    func jobShareMissing() throws {
        let script = TartGuestScript.make(tarball: "r.tar.gz")
        let check = try #require(script.range(of: #"[ -d "$JOB" ] || { echo "Error: job share missing at $JOB" >&2; exit 1; }"#))
        let run = try #require(script.range(of: "./run.sh"))
        #expect(check.lowerBound < run.lowerBound)
    }
}

/// The cache block of the guest script, run under /bin/bash in a temp folder with a fake
/// runner package (perl is the system perl, as in the guest).
@Suite("Tart guest script cache patch")
struct TartGuestScriptCacheTests {
    private static let url = "http://192.168.64.1:50123/"

    private static func utf16(_ text: String) -> [UInt8] { Array(text.data(using: .utf16LittleEndian)!) }

    private struct Run {
        let output: String
        let status: Int32
        let dll: [UInt8]
        let env: String
        /// What `bin/` holds afterwards: no temp copies left behind.
        let binFiles: [String]
    }

    /// Writes `bin/Runner.Worker.dll` (when `dll` is non-nil) and a `.env`, runs the cache block.
    private func run(dll: [UInt8]?, cacheURL: String, envIsWritable: Bool = true, hasEnv: Bool = true) throws -> Run {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("guest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("bin"), withIntermediateDirectories: true)
        if let dll { try Data(dll).write(to: folder.appendingPathComponent("bin/Runner.Worker.dll")) }
        if hasEnv { try Data("EXISTING=1\n".utf8).write(to: folder.appendingPathComponent(".env")) }
        if !envIsWritable {
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: folder.appendingPathComponent(".env").path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", TartGuestScript.cacheBlock, "_", "JIT", cacheURL]
        process.currentDirectoryURL = folder
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let dllAfter = (try? Data(contentsOf: folder.appendingPathComponent("bin/Runner.Worker.dll"))).map { [UInt8]($0) } ?? []
        let env = (try? String(contentsOf: folder.appendingPathComponent(".env"), encoding: .utf8)) ?? ""
        let binFiles = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("bin").path)) ?? []
        return Run(output: output, status: process.terminationStatus, dll: dllAfter, env: env, binFiles: binFiles.sorted())
    }

    private static func count(_ needle: [UInt8], in bytes: [UInt8]) -> Int {
        guard bytes.count >= needle.count else { return 0 }
        return (0 ... bytes.count - needle.count).filter { bytes[$0 ..< $0 + needle.count].elementsEqual(needle) }.count
    }

    private static let dll = [0x4D, 0x5A, 0x00] + utf16("ACTIONS_RESULTS_URL") + [0x00, 0x01] + utf16("ACTIONS_RUNTIME_URL")

    @Test("one copy of the string is patched and the URL goes in .env")
    func patched() throws {
        let result = try run(dll: Self.dll, cacheURL: Self.url)

        #expect(result.status == 0)
        #expect(Self.count(Self.utf16("ACTIONS_RESULTS_URL"), in: result.dll) == 0)
        #expect(Self.count(Self.utf16("ACTIONS_RESULTS_ORL"), in: result.dll) == 1)
        #expect(result.dll.count == Self.dll.count)
        #expect(result.env == "EXISTING=1\nACTIONS_RESULTS_URL=\(Self.url)\n")
        #expect(result.output.isEmpty)
        #expect(result.binFiles == ["Runner.Worker.dll"])
    }

    @Test("with no .env yet the runner is patched, the URL goes in a new .env, and nothing is printed")
    func noEnv() throws {
        let result = try run(dll: Self.dll, cacheURL: Self.url, hasEnv: false)

        #expect(result.status == 0)
        #expect(result.output.isEmpty)
        #expect(Self.count(Self.utf16("ACTIONS_RESULTS_ORL"), in: result.dll) == 1)
        #expect(result.env == "ACTIONS_RESULTS_URL=\(Self.url)\n")
    }

    @Test("when .env can't be written the runner stays unpatched, with one log line")
    func unwritableEnv() throws {
        let result = try run(dll: Self.dll, cacheURL: Self.url, envIsWritable: false)

        #expect(result.status == 0)
        #expect(result.dll == Self.dll)
        #expect(result.env == "EXISTING=1\n")
        #expect(result.binFiles == ["Runner.Worker.dll"])
        #expect(result.output.split(separator: "\n").count == 1)
        #expect(result.output.hasPrefix("Local cache off: "))
        #expect(result.output.hasSuffix("; this job uses GitHub's cache\n"))
    }

    @Test("no copy, two copies or no DLL leave everything as it was, with one log line", arguments: [
        [0x4D, 0x5A] + utf16("ACTIONS_RUNTIME_URL"),
        dll + utf16("ACTIONS_RESULTS_URL"),
        nil,
    ] as [[UInt8]?])
    func fallback(dll: [UInt8]?) throws {
        let result = try run(dll: dll, cacheURL: Self.url)

        #expect(result.status == 0)
        #expect(result.dll == (dll ?? []))
        #expect(result.env == "EXISTING=1\n")
        #expect(result.output.split(separator: "\n").count == 1)
        #expect(result.output.hasPrefix("Local cache off: "))
        #expect(result.output.hasSuffix("; this job uses GitHub's cache\n"))
        #expect(result.binFiles == (dll == nil ? [] : ["Runner.Worker.dll"]))
    }

    @Test("with no cache URL nothing changes")
    func noURL() throws {
        let result = try run(dll: Self.dll, cacheURL: "")

        #expect(result.dll == Self.dll)
        #expect(result.env == "EXISTING=1\n")
        #expect(result.output.isEmpty)
    }

    @Test("the cache block runs after extraction and before run.sh, and the URL rides in argv as $2")
    func wiring() throws {
        let script = TartGuestScript.make(tarball: "r.tar.gz")
        let extract = try #require(script.range(of: "tar xzf"))
        let block = try #require(script.range(of: TartGuestScript.cacheBlock))
        let run = try #require(script.range(of: "./run.sh"))
        #expect(extract.lowerBound < block.lowerBound && block.lowerBound < run.lowerBound)

        let command = TartGuestScript.command(tarball: "r.tar.gz", jitConfig: "JIT", cacheURL: URL(string: Self.url))
        #expect(command.suffix(3) == ["_", "JIT", Self.url])
        #expect(!command[2].contains(Self.url))
        #expect(TartGuestScript.command(tarball: "r.tar.gz", jitConfig: "JIT").suffix(2) == ["_", "JIT"])
    }
}


/// Ghast's job-started hook and the run-info watcher, run under /bin/bash in a temp folder
/// that stands in for the guest's home and runner folder.
@Suite("Tart guest script run info")
struct TartGuestScriptRunInfoTests {
    private struct Result {
        let output: String
        let status: Int32
        let folder: URL
    }

    private static let runEnvironment = [
        "GITHUB_REPOSITORY": "acme/app", "GITHUB_WORKFLOW": "CI", "GITHUB_RUN_ID": "42",
        "GITHUB_RUN_ATTEMPT": "2", "CUSTOM_VARIABLE": "kept",
    ]

    private func folder(files: [String: String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("guest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        return folder
    }

    /// Runs `arguments` in `folder` as the guest would, killing it if it hangs.
    private func run(_ arguments: [String], in folder: URL, environment: [String: String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = environment.merging(["HOME": folder.path, "PATH": "/usr/bin:/bin"]) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        watchdog.cancel()
        return Result(output: output, status: process.terminationStatus, folder: folder)
    }

    private func runHook(userScript: String?) throws -> Result {
        var files = ["ghast-job-started.sh": TartGuestScript.jobStartedHook]
        files["pre-job.sh"] = userScript
        let folder = try folder(files: files.compactMapValues { $0 })
        return try run(["--noprofile", "--norc", "-e", "-o", "pipefail", "ghast-job-started.sh"], in: folder, environment: Self.runEnvironment)
    }

    private func recordedInfo(_ folder: URL) throws -> [String: String]? {
        let line = try String(contentsOf: folder.appendingPathComponent(".ghast-run-info"), encoding: .utf8)
        return GuestRunInfo.parseMarker("ghast: run-info " + line.trimmingCharacters(in: .newlines))
    }

    @Test("the hook records the run, then runs the user's script with the same environment and keeps its exit code")
    func hookChainsUserScript() throws {
        let user = """
        #!/bin/bash
        env | sort > user-env.txt
        (compgen -v; declare -F) | grep -ci ghast > ghast-leak.txt || true
        echo "user script ran"
        exit 3
        """
        let result = try runHook(userScript: user)

        #expect(result.status == 3)
        #expect(result.output == "user script ran\n")
        #expect(try recordedInfo(result.folder) == [
            "repository": "acme/app", "workflow": "CI", "run_id": "42", "run_attempt": "2",
        ])
        let seen = try String(contentsOf: result.folder.appendingPathComponent("user-env.txt"), encoding: .utf8)
        for (name, value) in Self.runEnvironment { #expect(seen.contains("\(name)=\(value)\n")) }
        #expect(try String(contentsOf: result.folder.appendingPathComponent("ghast-leak.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "0")
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.folder.path).filter { $0.hasPrefix(".ghast-run-info.") }.isEmpty)
    }

    @Test("a user script that fails midway still decides the hook's status")
    func failingCommand() throws {
        let result = try runHook(userScript: "#!/bin/bash\nfalse\necho unreachable\n")
        #expect(result.status == 1)
        #expect(!result.output.contains("unreachable"))
    }

    @Test("without a user script the hook records the run and succeeds quietly")
    func hookAlone() throws {
        let result = try runHook(userScript: nil)
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
        #expect(try recordedInfo(result.folder)?["run_id"] == "42")
    }

    @Test("a hook that can't record (unwritable home) never fails the job")
    func recordingFailureIsHarmless() throws {
        let folder = try folder(files: ["ghast-job-started.sh": TartGuestScript.jobStartedHook])
        let result = try run(
            ["--noprofile", "--norc", "-e", "ghast-job-started.sh"], in: folder,
            environment: Self.runEnvironment.merging(["HOME": "/nonexistent-ghast-home"]) { $1 }
        )
        #expect(result.status == 0)
    }

    @Test("the run block prints one run-info line, exits with run.sh's status, and leaves nothing holding the stream")
    func runBlock() throws {
        let fakeRunner = """
        #!/bin/bash
        bash --noprofile --norc -e ghast-job-started.sh
        echo "Running job: build"
        sleep 1.5
        exit 7
        """
        let folder = try folder(files: ["ghast-job-started.sh": TartGuestScript.jobStartedHook, "run.sh": fakeRunner])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appendingPathComponent("run.sh").path)

        let result = try run(["-c", TartGuestScript.runBlock, "_", "JIT"], in: folder, environment: Self.runEnvironment)

        #expect(result.status == 7)
        let markers = result.output.split(separator: "\n").filter { $0.contains("ghast: run-info ") }
        #expect(markers.count == 1)
        let marker = try #require(markers.first)
        #expect(marker.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{4} ghast: run-info "#, options: .regularExpression) != nil)
        let text = String(marker.drop { $0 != "g" })
        #expect(GuestRunInfo.parseMarker(text)?["repository"] == "acme/app")
        #expect(result.output.contains("Running job: build"))
    }

    @Test("a stale info file in the image is removed before the run, so it is never reported")
    func staleFile() throws {
        let fakeRunner = "#!/bin/bash\nsleep 1.2\nexit 0\n"
        let folder = try folder(files: ["run.sh": fakeRunner, ".ghast-run-info": "repository=Zm9v\n"])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appendingPathComponent("run.sh").path)

        let result = try run(["-c", TartGuestScript.runBlock, "_", "JIT"], in: folder, environment: [:])

        #expect(result.status == 0)
        #expect(!result.output.contains("run-info"))
    }
}

@Suite("Tart guest script syntax")
struct TartGuestScriptSyntaxTests {
    @Test("the assembled script is valid bash")
    func parses() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", "-c", TartGuestScript.make(tarball: "r.tar.gz")]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        let errors = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, Comment(rawValue: errors))
    }
}
