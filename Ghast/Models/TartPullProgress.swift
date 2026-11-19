import Foundation

/// How far a VM image download has got. Indeterminate (no fraction) until Tart prints its
/// first percentage.
struct TartPullProgress: Sendable, Equatable {
    /// 0 to 1, once known.
    var fraction: Double?
    /// The compressed download size, e.g. "27.0 GB".
    var size: String?

    static let indeterminate = TartPullProgress(fraction: nil, size: nil)

    /// Whole percent for display, rounded down so 99.9% never reads 100.
    var percent: Int? { fraction.map { Int(($0 * 100).rounded(.down)) } }

    /// "42%" or "42% of 27.0 GB"; nil while indeterminate.
    var summary: String? {
        guard let percent else { return nil }
        return size.map { "\(percent)% of \($0)" } ?? "\(percent)%"
    }

    /// The progress after one more parsed event.
    func applying(_ event: TartPullEvent) -> TartPullProgress {
        switch event {
        case let .progress(fraction): TartPullProgress(fraction: fraction, size: size)
        case let .size(size): TartPullProgress(fraction: fraction, size: size)
        case .line: self
        }
    }
}
