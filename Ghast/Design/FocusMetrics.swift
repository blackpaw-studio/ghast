import CoreGraphics
import Foundation

/// Every size in the Focus design, named once. Views use these; none carries its own literals.
/// Values come from the spec's token table, except the three marked "measured", which were
/// taken from the @2x design PNGs (1 pt = 2 px).
enum FocusMetrics {
    // MARK: Windows
    static let mainWindowSize = CGSize(width: 1240, height: 780)
    static let mainWindowMinSize = CGSize(width: 900, height: 560)
    static let welcomeWindow = CGSize(width: 560, height: 520)
    static let settingsWidth: CGFloat = 620
    static let settingsPadding = CGSize(width: 28, height: 20)
    static let sheetWidth: CGFloat = 500
    static let sheetPadding: CGFloat = 24

    // MARK: Main window
    static let sidebarWidth: CGFloat = 248
    /// The kit's floating sidebar sits 8 pt in from the window edge on each side, so the detail
    /// column starts at 8 + 248 + 8 = 264. The native sidebar is full-bleed on the build host,
    /// so it takes the panel's whole footprint and the content lines up with the mockups.
    static let sidebarColumnWidth: CGFloat = 264
    static let sidebarMinWidth: CGFloat = 220
    static let sidebarMaxWidth: CGFloat = 320
    /// Measured: the content layer starts 64 pt below the window's top edge in every main
    /// window PNG (the kit's toolbar band), whatever height the native toolbar has.
    static let contentTop: CGFloat = 64
    static let contentInset: CGFloat = 32
    /// Measured: the Configuration form is 1277 / 1.68 ≈ 760 pt wide in Configuration.png.
    static let configurationMaxWidth: CGFloat = 760
    /// Measured: the environment-variable value column starts 260 pt after the name column.
    static let environmentNameColumn: CGFloat = 260

    // MARK: Status
    static let statusDot: CGFloat = 8
    /// Measured: the header dot in ErrorRunner.png is 16 px, the same 8 pt as the sidebar dot.
    /// (The spec's provisional 10 pt did not survive measurement.)
    static let statusDotHeader: CGFloat = 8
    static let runningHaloWidth: CGFloat = 3
    static let runningHaloOpacity = 0.22

    // MARK: Status header (measured from Main.png and ErrorRunner.png)
    /// From the content top (64) to the top of the title line.
    static let headerTop: CGFloat = 17
    static let headerDotSpacing: CGFloat = 10
    /// Title, secondary line, tokens and actions all start here, after the dot.
    static let headerTextIndent: CGFloat = statusDotHeader + headerDotSpacing
    static let headerTitleSpacing: CGFloat = 5
    static let headerTokensTop: CGFloat = 14
    static let headerActionsTop: CGFloat = 16
    static let headerActionSpacing: CGFloat = 8
    static let headerHintGap: CGFloat = 16
    /// From the last header row to the separator.
    static let headerBottom: CGFloat = 20
    /// "started 4 min ago" and Uptime refresh this often.
    static let headerRefreshInterval: TimeInterval = 30
    static let headerStatsGap: CGFloat = 24
    static let headerStatsTopOffset: CGFloat = 4
    static let statSpacing: CGFloat = 21
    static let statLabelSpacing: CGFloat = 3
    static let statSeparatorHeight: CGFloat = 28
    static let statSeparatorTop: CGFloat = 2

    // MARK: Rows and tokens
    static let tokenSpacing: CGFloat = 6
    static let runnerRowPadding = CGSize(width: 8, height: 7)
    /// Measured: the native sidebar row already adds 3 pt above and below its content, so 4 pt
    /// more gives the mockups' 46 pt row pitch.
    static let sidebarRowVerticalPadding: CGFloat = 4
    static let runnerRowRadius: CGFloat = 10
    static let runnerRowDotSpacing: CGFloat = 8
    static let tokenHeight: CGFloat = 20
    static let tokenHorizontalPadding: CGFloat = 7
    static let tokenRadius: CGFloat = 6

    // MARK: Output
    static let outputLineHeight: CGFloat = 19
    static let outputTimeColumn: CGFloat = 64
    /// Measured: glyphs centre 6 pt after the time column and the text starts 20 pt after it
    /// (the spec's 16 pt column did not survive measurement).
    static let outputGlyphColumn: CGFloat = 12
    static let outputGlyphTextGap: CGFloat = 8
    static let outputGlyphSize: CGFloat = 10
    static let outputCircleGlyphSize: CGFloat = 11
    static let cursorGap: CGFloat = 6
    /// Measured: 23 pt high, 2 pt below the line before it, 10 pt wider than the text on each side.
    static let liveLineHeight: CGFloat = 23
    static let liveLineTopGap: CGFloat = 2
    static let liveLineRadius: CGFloat = 6
    static let liveLineInset: CGFloat = 10
    static let cursorSize = CGSize(width: 7, height: 14)
    static let cursorBlinkInterval: TimeInterval = 0.6
    /// From the header separator to the centre of the "Output" row (201 − 177 − 8).
    static let outputHeaderTop: CGFloat = 16
    /// From the "Output" row to the first line.
    static let outputLinesTop: CGFloat = 18
    static let outputButtonSize: CGFloat = 16
    static let outputButtonSpacing: CGFloat = 16
    static let outputButtonGlyph: CGFloat = 13
    static let findFieldWidth: CGFloat = 260

    // MARK: Configuration form (measured from Configuration.png)
    static let formTop: CGFloat = 16
    static let formRowInset: CGFloat = 14
    static let formCaptionGap: CGFloat = 6
    static let formSectionGap: CGFloat = 24
    static let formBoxRadius: CGFloat = 10
    static let formRowHeight: CGFloat = 40
    static let formButtonRowHeight: CGFloat = 44
    static let formToggleRowHeight: CGFloat = 42
    static let environmentRowHeight: CGFloat = 36
    static let formAddRemoveTop: CGFloat = 8
    static let formHelpTop: CGFloat = 8
    static let formRemoveTop: CGFloat = 26
    static let addRemoveButtonWidth: CGFloat = 26
    static let addRemoveHeight: CGFloat = 22
    static let addRemoveDividerHeight: CGFloat = 14
    static let fieldRadius: CGFloat = 6
    static let invalidFieldOutset: CGFloat = 3
    static let scriptEditorHeight: CGFloat = 94
    static let scriptEditorPadding: CGFloat = 8
    static let scriptEditorRadius: CGFloat = 8
    /// The kit's mono text sits on a 19 pt line.
    static let scriptLineSpacing: CGFloat = 4
    static let scriptEditorExtraTop: CGFloat = 2

    // MARK: Welcome and empty states
    static let appIconLarge: CGFloat = 96
    static let appIconLargeRadius: CGFloat = 22
    static let appIconBanner: CGFloat = 32
    static let deviceCodeFontSize: CGFloat = 34
    static let deviceCodeTracking = 0.08
    static let deviceCodePadding = CGSize(width: 28, height: 16)
    static let deviceCodeRadius: CGFloat = 12
    static let emptyStateGlyph: CGFloat = 56
    static let emptyStateBodyMaxWidth: CGFloat = 380

    // MARK: Account
    static let accountAvatar: CGFloat = 64
    static let accountInitialsFontSize: CGFloat = 24
}
