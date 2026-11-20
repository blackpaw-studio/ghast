import SwiftUI

/// The kit's colour tokens as system semantics, so light, dark, Increase Contrast and the
/// accent colour all work.
enum FocusColor {
    /// `--fill`: label tokens, the live output line. Measured: the kit's 5% black is the
    /// tertiary fill (the spec's quaternary fill renders at 3%).
    static let fill = Color(nsColor: .tertiarySystemFill)
    /// `--sep`.
    static let separator = Color(nsColor: .separatorColor)
    /// `--label-3`, for non-text marks only.
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    /// `--group`: grouped form boxes.
    static let group = Color(nsColor: .quaternarySystemFill)
    /// Advisory warnings that never block (oversubscribed VM resources).
    static let warning = Color(nsColor: .systemOrange)
}
