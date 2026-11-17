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

    /// Chooses the Window menu's item for the SwiftUI `Window` scene titled `title`, which opens
    /// that window, or brings it forward, as clicking it would.
    static func openWindow(titled title: String) {
        guard let menu = NSApp.windowsMenu,
              let index = menu.items.firstIndex(where: { $0.title == title && $0.action != nil })
        else { return }
        menu.performActionForItem(at: index)
    }
}
