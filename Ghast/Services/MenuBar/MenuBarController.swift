import AppKit
import Observation

/// Where the status item lives, so tests and most fixture screens never add one.
@MainActor
protocol StatusItemHosting: AnyObject {
    func makeStatusItem() -> NSStatusItem?
    func remove(_ item: NSStatusItem)
}

/// The system menu bar.
@MainActor
final class SystemStatusItemHost: StatusItemHosting {
    func makeStatusItem() -> NSStatusItem? {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    }

    func remove(_ item: NSStatusItem) {
        NSStatusBar.system.removeStatusItem(item)
    }
}

/// Something the menu bar extra asks for.
enum MenuBarAction: Sendable, Equatable {
    case showOutput(runnerID: String)
    case start(runnerID: String)
    case stop(runnerID: String)
    case restart(runnerID: String)
    case command(MenuBarCommand)
}

/// What the controller shows: whether the extra is on, and its menu.
struct MenuBarState: Equatable {
    let isShown: Bool
    let entries: [MenuBarEntry]
}

/// Owns the `NSStatusItem` and its `NSMenu`. The menu is rebuilt whenever its description
/// changes, and the item is added or removed as the setting changes.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let host: any StatusItemHosting
    private let state: @MainActor () -> MenuBarState
    private let perform: @MainActor (MenuBarAction) -> Void
    private var statusItem: NSStatusItem?
    private var shown: MenuBarState?
    /// One menu for the item's life; its items are replaced in place, so an open menu updates.
    private let menu = NSMenu()
    private var menuOpened: (@MainActor (NSMenu) -> Void)?

    init(
        host: any StatusItemHosting,
        state: @escaping @MainActor () -> MenuBarState,
        perform: @escaping @MainActor (MenuBarAction) -> Void
    ) {
        self.host = host
        self.state = state
        self.perform = perform
        super.init()
        menu.autoenablesItems = false
        menu.minimumWidth = FocusMetrics.menuBarMenuWidth
        menu.delegate = self
    }

    /// Shows the extra (if on) and follows every change to its inputs.
    func start() {
        let current = withObservationTracking(state) {
            Task { @MainActor [weak self] in self?.start() }
        }
        apply(current)
    }

    /// Opens the menu with its top-left at `screenPoint`; `opened` runs as it opens. For the
    /// design fixture, which shows it on the capture display (the status item's own button
    /// lives on the main display's menu bar).
    func openMenu(at screenPoint: NSPoint, opened: @escaping @MainActor (NSMenu) -> Void) {
        guard statusItem != nil else { return }
        menuOpened = opened
        let menu = menu
        // popUp tracks the menu modally; return first so the caller isn't blocked.
        DispatchQueue.main.async {
            menu.popUp(positioning: nil, at: screenPoint, in: nil)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu, let opened = menuOpened else { return }
        menuOpened = nil
        opened(menu)
    }

    // MARK: -

    private func apply(_ next: MenuBarState) {
        guard next != shown else { return }
        shown = next
        guard next.isShown else {
            if let statusItem { host.remove(statusItem) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            statusItem = host.makeStatusItem()
            statusItem?.button?.image = MenuBarImages.ghost
            statusItem?.button?.toolTip = "Ghast"
            statusItem?.menu = menu
        }
        menu.items = next.entries.map(item(for:))
    }

    private func item(for entry: MenuBarEntry) -> NSMenuItem {
        switch entry {
        case let .sectionHeader(title):
            return NSMenuItem.sectionHeader(title: title)
        case let .placeholder(title):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .separator:
            return .separator()
        case let .runner(runner):
            return item(for: runner)
        case let .command(command, isEnabled):
            let item = actionItem(Self.title(for: command), .command(command), keyEquivalent: Self.keyEquivalent(for: command))
            item.isEnabled = isEnabled
            return item
        }
    }

    private func item(for runner: MenuBarRunnerEntry) -> NSMenuItem {
        let item = NSMenuItem(title: runner.name, action: nil, keyEquivalent: "")
        item.image = MenuBarImages.dot(runner.dot)
        // macOS 27 hides menu-item images unless asked; the status dot is the row's meaning.
        if #available(macOS 27, *) { item.preferredImageVisibility = .visible }
        // MenuBar.png sets the status word as plain secondary text before the chevron, not as a
        // badge pill: a right tab stop in the title.
        item.attributedTitle = Self.title(runner.name, status: runner.badge)
        item.setAccessibilityLabel("\(runner.name), \(runner.badge)")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for entry in runner.submenu {
            submenu.addItem(subitem(entry, runner: runner))
        }
        item.submenu = submenu
        return item
    }

    private func subitem(_ entry: MenuBarSubmenuItem, runner: MenuBarRunnerEntry) -> NSMenuItem {
        let item: NSMenuItem
        switch entry {
        case .separator: return .separator()
        case .showOutput: return actionItem("Show Output", .showOutput(runnerID: runner.id))
        case .start: item = actionItem("Start", .start(runnerID: runner.id))
        case .stop: item = actionItem("Stop", .stop(runnerID: runner.id))
        case .restart: item = actionItem("Restart", .restart(runnerID: runner.id))
        }
        item.isEnabled = runner.canControl
        return item
    }

    private func actionItem(_ title: String, _ action: MenuBarAction, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: keyEquivalent)
        item.target = self
        item.representedObject = ActionBox(action)
        return item
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else { return }
        perform(box.action)
    }

    private final class ActionBox: NSObject {
        let action: MenuBarAction
        init(_ action: MenuBarAction) { self.action = action }
    }

    private static func title(_ name: String, status: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: FocusMetrics.menuBarStatusTab)]
        let font = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(string: name, attributes: [.font: font, .paragraphStyle: paragraph])
        title.append(NSAttributedString(string: "\t" + status, attributes: [
            .font: font,
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return title
    }

    private static func title(for command: MenuBarCommand) -> String {
        switch command {
        case .startAll: return "Start All Runners"
        case .stopAll: return "Stop All Runners"
        case .newRunner: return "New Runner…"
        case .openGhast: return "Open Ghast"
        case .settings: return "Settings…"
        case .quit: return "Quit Ghast"
        }
    }

    private static func keyEquivalent(for command: MenuBarCommand) -> String {
        switch command {
        case .settings: return ","
        case .quit: return "q"
        default: return ""
        }
    }
}
