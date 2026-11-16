import SwiftUI

/// The kit's text styles. Nothing is below 10 pt.
enum FocusType {
    static let largeTitle = Font.system(size: 26, weight: .bold)
    static let title1 = Font.system(size: 22, weight: .bold)
    static let title2 = Font.system(size: 17, weight: .semibold)
    static let title3 = Font.system(size: 15, weight: .semibold)
    static let headline = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let callout = Font.system(size: 12)
    static let subheadline = Font.system(size: 11)
    /// Label tokens use Subheadline at weight 500.
    static let token = Font.system(size: 11, weight: .medium)
    static let footnote = Font.system(size: 10)
    static let outputSize: CGFloat = 12
    static let output = Font.system(size: outputSize, design: .monospaced)
    /// Measured: the mockups' mono text advances 7.22 pt a character, the system mono font
    /// 7.42 pt; this tracking closes the gap with the same glyphs.
    static let outputTracking: CGFloat = -0.2
    static let deviceCode = Font.system(size: FocusMetrics.deviceCodeFontSize, weight: .semibold, design: .monospaced)

    /// Line height for `output`, so rows line up with the kit's 19 pt grid.
    static let outputLineHeight = FocusMetrics.outputLineHeight
}
