import Darwin
import Foundation

/// Plain TCP to a loopback port, for checks below HTTP (a refused or timed-out connection).
enum RawConnection {
    struct Outcome {
        let received: [UInt8]
        /// The server closed the connection (EOF or reset) before `waitLimit`.
        let wasClosed: Bool
    }

    /// A loopback port that was free a moment ago.
    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = loopback(port: 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRNOTAVAIL) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// Opens a connection and keeps it open until the returned descriptor is closed.
    static func open(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = loopback(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        guard connected else {
            close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
        return fd
    }

    /// Sends `bytes` on `fd`, then reads until the server closes or `waitLimit` passes.
    static func exchange(_ fd: Int32, send bytes: [UInt8], waitLimit: Duration) async -> Outcome {
        await Task.detached {
            var timeout = timeval(tv_sec: Int(waitLimit.components.seconds),
                                  tv_usec: Int32(waitLimit.components.attoseconds / 1_000_000_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            if !bytes.isEmpty { _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) } }
            var received: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = recv(fd, &buffer, buffer.count, 0)
                if count > 0 { received += buffer[0 ..< count]; continue }
                let wasClosed = count == 0 || errno == ECONNRESET
                return Outcome(received: received, wasClosed: wasClosed)
            }
        }.value
    }

    private static func loopback(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }
}
