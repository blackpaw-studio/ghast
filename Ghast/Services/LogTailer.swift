import Foundation
import Observation

/// What a read of the log returned.
struct LogRead: Sendable, Equatable {
    let data: Data
    /// Where `data` starts in the file: the requested offset, or 0 after a restart.
    let startOffset: UInt64
    /// The file shrank or was replaced since the last read, so `data` starts from the top.
    let didRestart: Bool
}

/// Watches a log file and reads it by byte offset.
///
/// Owns the file-system source and file descriptor. It survives the file being deleted or
/// replaced (it reopens the path), and tells the owner whenever something changed.
///
/// Two ways to use it:
/// - text mode (`init(fileURL:load:)`): publishes the current text through `text`;
/// - incremental mode (`init(fileURL:onChange:)`): calls `onChange` once from `start()` and
///   again after every change; the owner calls `read(from:)` with the offset it has consumed.
@MainActor
@Observable
final class LogTailer {
    private(set) var text = ""

    @ObservationIgnored private var watch: FileWatch?
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private let load: (@MainActor () -> String)?
    /// Identity (device, inode) of the file the last `read` saw.
    @ObservationIgnored private var lastReadIdentity: FileIdentity?

    /// The watched descriptor, or -1 when not watching. Exposed for tests.
    var fileDescriptor: Int32 { watch?.fileDescriptor ?? -1 }

    /// Text mode.
    /// - Parameters:
    ///   - fileURL: The log file to watch; created on `start()` if missing. With `nil` there is
    ///     nothing to watch, and `start()` only publishes the current text.
    ///   - load: Reads the current log text (keeps placeholder text in one place).
    init(fileURL: URL?, load: @escaping @MainActor () -> String) {
        self.fileURL = fileURL
        self.load = load
    }

    /// Incremental mode.
    init(fileURL: URL, onChange: @escaping @MainActor () -> Void) {
        self.fileURL = fileURL
        self.load = nil
        self.onChange = onChange
    }

    deinit {
        // The cancel handler closes the descriptor.
        watch?.cancel()
    }

    /// Starts watching and notifies once. Does nothing if already started.
    func start() {
        guard watch == nil else { return }
        openWatch()
        notify()
    }

    /// Re-reads the file and publishes the text if it changed (text mode).
    func reload() {
        guard let load else { return }
        let latest = load()
        if latest != text { text = latest }
    }

    /// Stops watching. Returns once the descriptor is closed.
    func stop() async {
        guard let watch else { return }
        self.watch = nil
        await watch.cancelAndWait()
    }

    /// The bytes from `offset` to the end of the file. If the file shrank below `offset`, or is
    /// a different file than the last read saw, starts over from 0 and says so.
    func read(from offset: UInt64) -> LogRead {
        guard let fileURL, let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return LogRead(data: Data(), startOffset: offset, didRestart: false)
        }
        defer { try? handle.close() }

        let identity = FileIdentity(descriptor: handle.fileDescriptor)
        let size = (try? handle.seekToEnd()) ?? 0
        let replaced = lastReadIdentity != nil && identity != nil && identity != lastReadIdentity
        lastReadIdentity = identity

        let restart = replaced || offset > size
        let start = restart ? 0 : offset
        guard (try? handle.seek(toOffset: start)) != nil else {
            return LogRead(data: Data(), startOffset: start, didRestart: restart)
        }
        let data = (try? handle.readToEnd()) ?? Data()
        return LogRead(data: data, startOffset: start, didRestart: restart)
    }

    // MARK: -

    private func notify() {
        if let onChange { onChange() } else { reload() }
    }

    private func openWatch() {
        guard let fileURL else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        watch = FileWatch(path: fileURL.path) { [weak self] eventBits in
            // The source runs its handler on the main queue.
            MainActor.assumeIsolated { self?.handle(DispatchSource.FileSystemEvent(rawValue: eventBits)) }
        }
    }

    private func handle(_ event: DispatchSource.FileSystemEvent) {
        if !event.isDisjoint(with: [.delete, .rename]) {
            // The path now names a different file (or none): drop the stale descriptor and
            // watch whatever is there.
            watch?.cancel()
            openWatch()
        }
        notify()
    }
}

/// A file's device and inode: two reads of one path from different files differ.
private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init?(descriptor: Int32) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}

/// A file-system source plus the descriptor it watches. Immutable, so the nonisolated
/// `deinit` of its owner can cancel it.
private final class FileWatch: Sendable {
    let fileDescriptor: Int32
    private let source: any DispatchSourceFileSystemObject

    init?(path: String, onEvent: @escaping @Sendable (UInt) -> Void) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        fileDescriptor = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { onEvent(source.data.rawValue) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func cancel() {
        source.cancel()
    }

    func cancelAndWait() async {
        let descriptor = fileDescriptor
        await withCheckedContinuation { continuation in
            source.setCancelHandler {
                close(descriptor)
                continuation.resume()
            }
            source.cancel()
        }
    }
}
