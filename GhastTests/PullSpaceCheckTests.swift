import Testing
import Foundation
@testable import Ghast

@Suite("Pull space check")
struct PullSpaceCheckTests {
    private let image = "ghcr.io/cirruslabs/macos-tahoe-xcode:26.3"
    private let disk: Int64 = 140_000_000_000
    private let reserve = PullSpaceCheck.reserveBytes

    @Test("the reserve is Tart's own 128 MiB")
    func reserveSize() {
        #expect(PullSpaceCheck.reserveBytes == 128 * 1024 * 1024)
    }

    @Test("an image that won't fit is blocked with what it needs and what is free")
    func blocks() {
        let free: Int64 = 88_400_000_000

        let error = PullSpaceCheck.shortfall(image: image, requiredDiskBytes: disk, freeBytes: free)

        #expect(error == .insufficientSpace(image: image, neededBytes: disk, freeBytes: free))
    }

    @Test("an image that fits exactly with the reserve passes; one byte less free blocks")
    func boundary() {
        #expect(PullSpaceCheck.shortfall(image: image, requiredDiskBytes: disk, freeBytes: disk + reserve) == nil)
        #expect(PullSpaceCheck.shortfall(image: image, requiredDiskBytes: disk, freeBytes: disk + reserve - 1) != nil)
    }

    @Test("an unknown image size or unknown free space never blocks")
    func unknown() {
        #expect(PullSpaceCheck.shortfall(image: image, requiredDiskBytes: nil, freeBytes: 1) == nil)
        #expect(PullSpaceCheck.shortfall(image: image, requiredDiskBytes: disk, freeBytes: nil) == nil)
    }

    @Test("the message is the spec copy: short ref, needs rounded up, free rounded down")
    func message() {
        let error = TartBackendError.insufficientSpace(image: image, neededBytes: 139_200_000_000, freeBytes: 88_900_000_000)

        #expect(error.errorDescription == "Not enough disk space to pull macos-tahoe-xcode:26.3: needs about 140 GB, 88 GB free. Free space in Settings › General › Tart Storage.")
    }

    @Test("a blocked pull is not transient: retrying can't make room")
    func notTransient() {
        let error = TartBackendError.insufficientSpace(image: image, neededBytes: 1, freeBytes: 0)

        #expect(!TartBackend.isTransient(error))
    }

    @Test("short names: repository leaf plus tag, or a 12-digit digest", arguments: [
        ("ghcr.io/cirruslabs/macos-tahoe-xcode:26.3", "macos-tahoe-xcode:26.3"),
        ("ghcr.io/cirruslabs/macos-tahoe-base", "macos-tahoe-base:latest"),
        ("ghcr.io/cirruslabs/macos-tahoe-xcode@sha256:923c98d32e40ffadb6e6815a9722124b7a57bdf7d7763a708a2b28d1970831bd", "macos-tahoe-xcode@sha256:923c98d32e40"),
        ("my-local-vm", "my-local-vm"),
    ])
    func shortName(ref: String, expected: String) {
        #expect(TartImageRef.shortName(of: ref) == expected)
    }
}
