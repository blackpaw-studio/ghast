import Foundation
import os

enum JobHistoryStoreError: Error, Equatable {
    case invalidRunnerID(String)
}

/// Where a runner's job records live between launches.
protocol JobHistoryStoring: Sendable {
    /// The saved records, or none: a missing file is empty, and a file that won't decode is set aside.
    func load(runnerID: String) -> [JobHistoryRecord]
    func save(_ records: [JobHistoryRecord], runnerID: String) throws
    func delete(runnerID: String) throws
}

/// `~/.ghast/history/<runner id>.json`: the folder is 0700, each file 0600 and replaced
/// whole through a temporary file and a rename.
struct FileJobHistoryStore: JobHistoryStoring {
    private static let logger = Logger(subsystem: "net.evancoleman.ghast", category: "job-history")
    let root: URL

    func load(runnerID: String) -> [JobHistoryRecord] {
        guard let file = try? fileURL(runnerID), let data = try? Data(contentsOf: file) else { return [] }
        do {
            return try Self.decoder.decode([JobHistoryRecord].self, from: data)
        } catch {
            let corrupt = file.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: corrupt)
            try? FileManager.default.moveItem(at: file, to: corrupt)
            Self.logger.error("Job history for runner \(runnerID, privacy: .public) couldn't be read (\(String(describing: error), privacy: .public)); moved to \(corrupt.lastPathComponent, privacy: .public) and starting empty")
            return []
        }
    }

    func save(_ records: [JobHistoryRecord], runnerID: String) throws {
        let file = try fileURL(runnerID)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let temporary = root.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: try Self.encoder.encode(records), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        guard rename(temporary.path, file.path) == 0 else {
            let code = errno
            try? manager.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    func delete(runnerID: String) throws {
        let file = try fileURL(runnerID)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    /// The runner id becomes a file name, so only a plain name is accepted.
    private func fileURL(_ runnerID: String) throws -> URL {
        guard !runnerID.isEmpty, runnerID != ".", runnerID != "..",
              runnerID.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\\0")) == nil
        else { throw JobHistoryStoreError.invalidRunnerID(runnerID) }
        return root.appendingPathComponent("\(runnerID).json")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Keeps records in memory: for tests and the design fixture, which never touch `~/.ghast`.
final class InMemoryJobHistoryStore: JobHistoryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: [JobHistoryRecord]]
    private(set) var saveCount = 0

    init(_ stored: [String: [JobHistoryRecord]] = [:]) { self.stored = stored }

    func load(runnerID: String) -> [JobHistoryRecord] { lock.withLock { stored[runnerID] ?? [] } }

    func save(_ records: [JobHistoryRecord], runnerID: String) throws {
        lock.withLock {
            stored[runnerID] = records
            saveCount += 1
        }
    }

    func delete(runnerID: String) throws { lock.withLock { stored[runnerID] = nil } }
}
