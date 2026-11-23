import Foundation

protocol SoftnetHelperChecking: Sendable {
    func status() async -> SoftnetHelperStatus
    /// The softnet that setup copies from; nil when there is none.
    func locateSource() -> URL?
}

/// Decides whether the installed helper is safe to run and current.
struct SoftnetHelperChecker: SoftnetHelperChecking {
    /// Folders searched for the source softnet before the inherited `PATH`: the ones Ghast also
    /// searches for `tart`. A GUI app's own `PATH` never holds Homebrew.
    static let knownFolders = TartLocator.knownPaths.map { ($0 as NSString).deletingLastPathComponent }

    /// Each of these must be a real, root-owned folder nobody else can write to.
    private static let guardedFolders = [
        SoftnetHelperScripts.helperDirectory, "/usr/local/libexec", "/usr/local", "/usr", "/",
    ]
    private static let setuidBit: UInt16 = 0o4000
    private static let groupOtherWriteBits: UInt16 = 0o022

    let inspector: any FileInspecting
    let versions: any SoftnetVersionReading
    let inheritedPath: String

    init(
        inspector: any FileInspecting = SystemFileInspector(),
        versions: any SoftnetVersionReading = ProcessSoftnetVersionReader(),
        inheritedPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) {
        self.inspector = inspector
        self.versions = versions
        self.inheritedPath = inheritedPath
    }

    func locateSource() -> URL? {
        let folders = Self.knownFolders + inheritedPath.split(separator: ":").map(String.init)
        return folders
            .filter { !$0.isEmpty && $0 != SoftnetHelperScripts.helperDirectory }
            .map { $0 + "/softnet" }
            .first(where: inspector.isExecutable(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }

    func status() async -> SoftnetHelperStatus {
        let source = locateSource()
        guard let entry = inspector.entry(atPath: SoftnetHelperScripts.helperPath) else {
            return source == nil ? .softnetMissing : .notInstalled
        }
        if let reason = fileProblem(entry) ?? folderProblem() { return .unsafe(reason) }

        let helper = URL(fileURLWithPath: SoftnetHelperScripts.helperPath)
        guard let installed = await versions.version(of: helper) else { return .unsafe(.doesNotRun) }
        guard let source, let available = await versions.version(of: source) else { return .ready(version: installed) }
        return installed == available ? .ready(version: installed) : .outdated(installed: installed, available: available)
    }

    private func fileProblem(_ entry: FileEntry) -> UnsafeReason? {
        if entry.kind == .symlink { return .symlink }
        if entry.kind != .file { return .notRegularFile }
        if entry.ownerID != 0 { return .notOwnedByRoot }
        if entry.mode & Self.setuidBit == 0 { return .notSetuid }
        if entry.mode & Self.groupOtherWriteBits != 0 || entry.hasWriteACL { return .writableByOthers }
        return nil
    }

    private func folderProblem() -> UnsafeReason? {
        Self.guardedFolders.first { path in
            guard let entry = inspector.entry(atPath: path) else { return true }
            return entry.kind != .directory || entry.ownerID != 0
                || entry.mode & Self.groupOtherWriteBits != 0 || entry.hasWriteACL
        }.map(UnsafeReason.unsafeFolder)
    }
}

/// For a backend built without isolation support (tests, the design fixture): never ready.
struct NoSoftnetHelper: SoftnetHelperChecking {
    func status() async -> SoftnetHelperStatus { .notInstalled }
    func locateSource() -> URL? { nil }
}
