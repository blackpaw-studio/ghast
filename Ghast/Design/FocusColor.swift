import SwiftUI

/// The kit's colour tokens as system semantics, so light, dark, Increase Contrast and the
/// accent colour all work.
enum FocusColor {
    /// `--fill`: label tokens, the live output line.
    static let fill = Color(nsColor: .quaternarySystemFill)
    /// `--sep`.
    static let separator = Color(nsColor: .separatorColor)
    /// `--label-3`, for non-text marks only.
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    /// `--group`: grouped form boxes.
    static let group = Color(nsColor: .quaternarySystemFill)
}
