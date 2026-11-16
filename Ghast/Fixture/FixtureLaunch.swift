#if DEBUG
import Foundation

/// The 12 mockup screens a design fixture can show.
enum FixtureScreen: String, CaseIterable, Sendable {
    case main
    case configuration
    case remote
    case error
    case firstRun = "first-run"
    case welcome
    case deviceCode = "device-code"
    case newRunner = "new-runner"
    case newRunnerProgress = "new-runner-progress"
    case settingsGeneral = "settings-general"
    case settingsAccount = "settings-account"
    case menuBar = "menu-bar"

    /// Screens shown before sign-in: the fixture holds no token for them.
    var isSignedOut: Bool {
        self == .welcome || self == .deviceCode
    }
}

enum FixtureLaunchError: Error, Equatable, CustomStringConvertible {
    case missingScreen
    case unknownScreen(String)
    case unknownAppearance(String)

    var description: String {
        switch self {
        case .missingScreen:
            return "-GhastDesignFixture needs a screen: \(FixtureScreen.allCases.map(\.rawValue).joined(separator: ", "))"
        case let .unknownScreen(name):
            return "Unknown fixture screen '\(name)'. Expected one of: \(FixtureScreen.allCases.map(\.rawValue).joined(separator: ", "))"
        case let .unknownAppearance(name):
            return "Unknown -GhastAppearance '\(name)'. Expected light or dark."
        }
    }
}

/// `Ghast -GhastDesignFixture <screen> [-GhastAppearance dark]`.
struct FixtureLaunch: Equatable, Sendable {
    static let screenFlag = "-GhastDesignFixture"
    static let appearanceFlag = "-GhastAppearance"

    let screen: FixtureScreen
    let isDark: Bool

    /// Returns nil when the fixture flag is absent. A malformed flag throws, so a typo can
    /// never fall through to a normal launch against the user's real runners.
    static func parse(_ arguments: [String]) throws(FixtureLaunchError) -> FixtureLaunch? {
        guard let flagIndex = arguments.firstIndex(of: screenFlag) else { return nil }
        guard let name = value(after: flagIndex, in: arguments) else { throw .missingScreen }
        guard let screen = FixtureScreen(rawValue: name) else { throw .unknownScreen(name) }
        return FixtureLaunch(screen: screen, isDark: try isDark(arguments))
    }

    private static func isDark(_ arguments: [String]) throws(FixtureLaunchError) -> Bool {
        guard let index = arguments.firstIndex(of: appearanceFlag) else { return false }
        switch value(after: index, in: arguments) {
        case "dark": return true
        case "light": return false
        case let other: throw .unknownAppearance(other ?? "")
        }
    }

    private static func value(after index: Int, in arguments: [String]) -> String? {
        let next = index + 1
        guard next < arguments.count, !arguments[next].hasPrefix("-") else { return nil }
        return arguments[next]
    }
}

/// Where the mockup puts a window, in points on a 1440 x 900 pt screen, measured from the
/// screen's top-left.
struct FixtureWindowPlacement: Equatable, Sendable {
    static let screenSize = CGSize(width: 1440, height: 900)

    let size: CGSize
    let topLeft: CGPoint

    /// The window frame in AppKit's bottom-left global coordinates on `screenFrame`.
    func frame(onScreen screenFrame: CGRect) -> CGRect {
        // AppKit's y axis runs upward; the mockup's runs downward from the screen's top edge.
        CGRect(
            x: screenFrame.minX + topLeft.x,
            y: screenFrame.maxY - topLeft.y - size.height,
            width: size.width,
            height: size.height
        )
    }
}

extension FixtureScreen {
    private static let mainWindow = FixtureWindowPlacement(size: CGSize(width: 1240, height: 780), topLeft: CGPoint(x: 100, y: 60))

    /// What the main window opens on for this screen; nil for screens without it.
    var mainWindowPreset: MainWindowPreset? {
        switch self {
        case .main, .newRunner, .newRunnerProgress: return MainWindowPreset(runnerName: "dionysus-xcode", tab: .output)
        case .configuration: return MainWindowPreset(runnerName: "dionysus-xcode", tab: .configuration)
        case .remote: return MainWindowPreset(runnerName: "helios-linux", tab: .output)
        case .error: return MainWindowPreset(runnerName: "ghast-release", tab: .output)
        case .firstRun: return MainWindowPreset(runnerName: nil, tab: .output)
        case .welcome, .deviceCode, .settingsGeneral, .settingsAccount, .menuBar: return nil
        }
    }

    /// The first-run screen is the window right after sign-in: no runners on this Mac yet.
    var hasLocalRunners: Bool { self != .firstRun }

    /// nil when the screen has no window of its own (the menu bar extra).
    var placement: FixtureWindowPlacement? {
        switch self {
        case .main, .configuration, .remote, .error, .firstRun, .newRunner, .newRunnerProgress:
            return Self.mainWindow
        case .welcome:
            return FixtureWindowPlacement(size: CGSize(width: 560, height: 520), topLeft: CGPoint(x: 120, y: 190))
        case .deviceCode:
            return FixtureWindowPlacement(size: CGSize(width: 560, height: 520), topLeft: CGPoint(x: 760, y: 190))
        case .settingsGeneral:
            return FixtureWindowPlacement(size: CGSize(width: 620, height: 660), topLeft: CGPoint(x: 60, y: 120))
        case .settingsAccount:
            return FixtureWindowPlacement(size: CGSize(width: 620, height: 660), topLeft: CGPoint(x: 760, y: 120))
        case .menuBar:
            return nil
        }
    }
}
#endif
