import Foundation

struct TartVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// The first `x.y.z` in `text` (`tart --version` prints just that, a build suffix aside).
    init?(parsing text: String) {
        guard let match = text.firstMatch(of: /(\d+)\.(\d+)\.(\d+)/),
              let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3)
        else { return nil }
        self.init(major, minor, patch)
    }

    static func < (lhs: TartVersion, rhs: TartVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

/// What the locator found.
enum TartInstallation: Equatable, Sendable {
    case found(URL, version: TartVersion)
    /// Installed, but older than `TartLocator.minimumVersion`.
    case tooOld(URL, version: TartVersion)
    case missing

    var executable: URL? {
        switch self {
        case let .found(url, _): url
        case .tooOld, .missing: nil
        }
    }

    var isUsable: Bool { executable != nil }

    static let installCommand = "brew install openai/tools/tart"
    /// Older Tart came from the `cirruslabs/cli` tap, whose formula is gone.
    static let reinstallCommand = "brew uninstall tart && brew install openai/tools/tart"
}

/// The machine facts the locator needs, behind a seam so tests never look at the real one.
protocol TartEnvironment: Sendable {
    func isExecutable(_ path: String) -> Bool
    /// What the user's login shell prints for `command -v tart`; nil when it prints nothing.
    func loginShellLookup() async -> String?
    /// The output of `tart --version`; nil when it cannot run.
    func versionOutput(of tart: URL) async -> String?
}

/// Finds `tart`: `/opt/homebrew/bin`, `/usr/local/bin`, then the login shell's `PATH` (the
/// GUI app's own `PATH` does not hold Homebrew).
struct TartLocator: Sendable {
    static let minimumVersion = TartVersion(2, 27, 0)
    static let knownPaths = ["/opt/homebrew/bin/tart", "/usr/local/bin/tart"]

    let environment: any TartEnvironment

    init(environment: any TartEnvironment = SystemTartEnvironment()) {
        self.environment = environment
    }

    /// A binary whose version cannot be read counts as missing.
    func locate() async -> TartInstallation {
        guard let path = await findExecutable(),
              let output = await environment.versionOutput(of: URL(fileURLWithPath: path)),
              let version = TartVersion(parsing: output)
        else { return .missing }
        let url = URL(fileURLWithPath: path)
        return version >= Self.minimumVersion ? .found(url, version: version) : .tooOld(url, version: version)
    }

    private func findExecutable() async -> String? {
        if let known = Self.knownPaths.first(where: environment.isExecutable) { return known }
        guard let answer = await environment.loginShellLookup() else { return nil }
        let path = answer.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        guard let path, path.hasPrefix("/"), environment.isExecutable(path) else { return nil }
        return path
    }
}

struct SystemTartEnvironment: TartEnvironment {
    func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    func loginShellLookup() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return await Self.output(of: URL(fileURLWithPath: shell), ["-lc", "command -v tart"])
    }

    func versionOutput(of tart: URL) async -> String? {
        await Self.output(of: tart, ["--version"])
    }

    private static func output(of executable: URL, _ arguments: [String]) async -> String? {
        let result = try? await ProcessRun.run(
            executable: executable,
            arguments: arguments,
            in: FileManager.default.temporaryDirectory
        )
        guard let result, result.status == 0 else { return nil }
        return result.output
    }
}
