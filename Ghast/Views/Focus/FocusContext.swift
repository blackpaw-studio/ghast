import SwiftUI
import Foundation

/// The injected time and host the Focus views write their words against, so tests and the
/// design fixture control them.
struct FocusContext: Sendable {
    let clock: any AppClock
    let hostInfo: any HostInfo
    var calendar: Calendar = .current
    /// False in the design fixture, so a capture never catches the cursor mid-blink.
    var animatesCursor = true
    var sleeper: Sleeper = { try await Task.sleep(for: $0) }
    /// False in the design fixture: a device code is never copied or opened in the browser.
    var performsDeviceFlowSideEffects = true
    /// How a runner folder is written ("~/.ghast/runners/dionysus-xcode").
    var displayPath: @Sendable (String) -> String = { ($0 as NSString).abbreviatingWithTildeInPath }

    var displayTime: DisplayTime { .current(now: clock.now(), calendar: calendar) }

    static let live = FocusContext(clock: SystemClock(), hostInfo: SystemHostInfo())
}

/// What the main window shows when it opens, overriding the restored selection. Only the
/// design fixture sets it.
struct MainWindowPreset: Equatable, Sendable {
    /// The runner to select, by name; nil for the This Mac empty state.
    let runnerName: String?
    let tab: DetailTab
    /// Opens the New Runner sheet on this state.
    var newRunner: NewRunnerSheetPreset? = nil
}

extension EnvironmentValues {
    @Entry var focusContext: FocusContext = .live
    @Entry var mainWindowPreset: MainWindowPreset?
}
