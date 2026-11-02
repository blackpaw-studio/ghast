import Foundation
import Observation

/// Tails a log file: publishes its current text and refreshes it whenever the file grows.
///
/// Owns the file-system source and file descriptor, so a view only renders `text`.
@MainActor
@Observable
final class LogTailer {
    private(set) var text = ""

    @ObservationIgnored private var watch: FileWatch?
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let load: @MainActor () -> String

    /// The watched descriptor, or -1 when not watching. Exposed for tests.
    var fileDescriptor: Int32 { watch?.fileDescriptor ?? -1 }

    /// - Parameters:
    ///   - fileURL: The log file to watch; created on `start()` if missing. With `nil` there is
    ///     nothing to watch, and `start()` only publishes the current text.
    ///   - load: Reads the current log text (keeps placeholder text in one place).
    init(fileURL: URL?, load: @escaping @MainActor () -> String) {
        self.fileURL = fileURL
        self.load = load
    }

    deinit {
        // The cancel handler closes the descriptor.
        watch?.cancel()
    }

    /// Starts watching and publishes the current content. Does nothing if already started.
    func start() {
        guard watch == nil else { return }
        if let fileURL {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            watch = FileWatch(path: fileURL.path) { [weak self] in
                // The source runs its handler on the main queue.
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        reload()
    }

    /// Re-reads the file and publishes the text if it changed.
    func reload() {
        let latest = load()
        if latest != text { text = latest }
    }

    /// Stops watching. Returns once the descriptor is closed.
    func stop() async {
        guard let watch else { return }
        self.watch = nil
        await watch.cancelAndWait()
    }
}

/// A file-system source plus the descriptor it watches. Immutable, so the nonisolated
/// `deinit` of its owner can cancel it.
private final class FileWatch: Sendable {
    let fileDescriptor: Int32
    private let source: any DispatchSourceFileSystemObject

    init?(path: String, onChange: @escaping @Sendable () -> Void) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        fileDescriptor = descriptor
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend],
            queue: .main
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
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
