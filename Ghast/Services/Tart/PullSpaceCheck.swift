import Foundation

/// Whether an image fits in the free space before `tart pull` starts.
enum PullSpaceCheck {
    /// The reservation Tart itself requires on top of the image's disk before it pulls.
    static let reserveBytes: Int64 = 128 * 1024 * 1024

    /// The error to stop with, or nil when the image fits or either size is unknown.
    static func shortfall(image: String, requiredDiskBytes: Int64?, freeBytes: Int64?) -> TartBackendError? {
        guard let requiredDiskBytes, let freeBytes else { return nil }
        guard requiredDiskBytes + reserveBytes > freeBytes else { return nil }
        return .insufficientSpace(image: image, neededBytes: requiredDiskBytes, freeBytes: freeBytes)
    }
}
