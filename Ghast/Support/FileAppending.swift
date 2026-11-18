import Foundation

enum FileAppending {
    /// Opens `url` for writing in `O_APPEND` mode, creating it if missing, so Ghast's own
    /// lines and a child process's output interleave instead of overwriting each other.
    static func openHandle(_ url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
