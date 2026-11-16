import Foundation

/// Registers an existing runner with its scope again under a fresh token, keeping its name,
/// labels, group and work folder (`config.sh --replace`), then starts it.
@MainActor
struct RunnerReconfigurer {
    /// The files that mark a folder as configured; `config.sh` refuses to run while they exist.
    static let registrationFiles = [".runner", ".credentials", ".credentials_rsaparams"]

    let services: RunnerFlowServices

    /// Stop → new token → set the old registration aside → `config.sh --replace` → start.
    /// On failure the old registration is put back and the runner stays stopped. On success
    /// the old files go to the Trash as one folder; nothing is deleted.
    func reconfigure(_ runner: LocalRunner) async throws {
        await services.runnerService.stopRunner(id: runner.id)
        let token = try await services.api.createRegistrationToken(for: runner.scope)
        let folder = URL(fileURLWithPath: runner.path)
        let backup = try setAside(in: folder)
        do {
            try await services.registrar.register(RunnerRegistration(runner), token: token.token, in: folder, replace: true)
        } catch {
            restore(backup, into: folder)
            throw error
        }
        if let backup { try? await services.trasher.trash(backup) }
        try await services.runnerService.startRunner(id: runner.id)
    }

    /// Moves the registration files into a hidden folder in the runner folder. nil when there
    /// were none.
    private func setAside(in folder: URL) throws -> URL? {
        let fileManager = FileManager.default
        let present = Self.registrationFiles.filter { fileManager.fileExists(atPath: folder.appendingPathComponent($0).path) }
        guard !present.isEmpty else { return nil }
        let backup = folder.appendingPathComponent(".reconfigure-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: false)
        do {
            for file in present {
                try fileManager.moveItem(at: folder.appendingPathComponent(file), to: backup.appendingPathComponent(file))
            }
        } catch {
            restore(backup, into: folder)
            throw error
        }
        return backup
    }

    /// Puts set-aside files back, replacing anything a failed `config.sh` left in their place.
    private func restore(_ backup: URL?, into folder: URL) {
        guard let backup else { return }
        let fileManager = FileManager.default
        for file in Self.registrationFiles {
            let saved = backup.appendingPathComponent(file)
            guard fileManager.fileExists(atPath: saved.path) else { continue }
            let target = folder.appendingPathComponent(file)
            if fileManager.fileExists(atPath: target.path) {
                _ = try? fileManager.replaceItemAt(target, withItemAt: saved)
            } else {
                try? fileManager.moveItem(at: saved, to: target)
            }
        }
        // Empty now; removing an empty folder Ghast made a moment ago loses nothing.
        if (try? fileManager.contentsOfDirectory(atPath: backup.path))?.isEmpty == true {
            try? fileManager.removeItem(at: backup)
        }
    }
}
