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
        #expect(script.contains(#"exit "${PIPESTATUS[0]}""#))
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
        for (file, hook) in [("pre-job.sh", "ACTIONS_RUNNER_HOOK_JOB_STARTED"), ("post-job.sh", "ACTIONS_RUNNER_HOOK_JOB_COMPLETED")] {
            #expect(script.contains("""
            if [ -f "$JOB/\(file)" ]; then
                cp "$JOB/\(file)" \(file) && chmod +x \(file) || exit 1
                echo "\(hook)=$PWD/\(file)" >> .env
            fi
            """))
        }
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
    private static let url = "http://192.168.64.1:50123/v/abc/"

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
    private func run(dll: [UInt8]?, cacheURL: String, envIsWritable: Bool = true) throws -> Run {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("guest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("bin"), withIntermediateDirectories: true)
        if let dll { try Data(dll).write(to: folder.appendingPathComponent("bin/Runner.Worker.dll")) }
        try Data("EXISTING=1\n".utf8).write(to: folder.appendingPathComponent(".env"))
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
