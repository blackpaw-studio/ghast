import AppKit

/// The app menu, for places with no SwiftUI environment.
@MainActor
enum AppMenu {
    /// Chooses the app menu's Settings… item, as ⌘, would.
    static func openSettings() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command })
        else { return }
        appMenu.performActionForItem(at: index)
    }
}
