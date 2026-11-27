import Foundation

/// What the main window's detail shows.
enum MainSelection: Hashable, Sendable {
    /// No runners on this Mac: the This Mac empty state.
    case thisMacEmpty
    case runner(RunnerItem.ID)

    private static let emptyStorageValue = "this-mac-empty"
    private static let runnerPrefix = "runner:"

    /// For `@SceneStorage`, which only holds plain values.
    var storageValue: String {
        switch self {
        case .thisMacEmpty: return Self.emptyStorageValue
        case let .runner(id): return Self.runnerPrefix + id
        }
    }

    init?(storageValue: String) {
        if storageValue == Self.emptyStorageValue {
            self = .thisMacEmpty
        } else if storageValue.hasPrefix(Self.runnerPrefix) {
            self = .runner(String(storageValue.dropFirst(Self.runnerPrefix.count)))
        } else {
            return nil
        }
    }

    /// The selection to show in `catalog`, given what was shown in `previous`.
    ///
    /// A runner that still exists stays selected. One that disappeared hands over to the local
    /// runner that took its place in the list (or the new last one). With no local runners the
    /// This Mac empty state shows, even when other machines have runners; a remote runner the
    /// user picks in that state stays selected while it exists.
    func resolved(in catalog: RunnerCatalog, previous: RunnerCatalog?) -> MainSelection {
        switch self {
        case let .runner(id) where catalog.contains(id):
            return self
        case let .runner(id):
            guard !catalog.thisMac.isEmpty else { return .thisMacEmpty }
            let index = previous?.thisMac.firstIndex { $0.id == id } ?? 0
            return .runner(catalog.thisMac[min(index, catalog.thisMac.count - 1)].id)
        case .thisMacEmpty:
            return catalog.thisMac.first.map { .runner($0.id) } ?? .thisMacEmpty
        }
    }
}

extension Optional where Wrapped == MainSelection {
    /// Nothing stored yet (first launch): the first runner on this Mac, else the empty state.
    func resolved(in catalog: RunnerCatalog, previous: RunnerCatalog?) -> MainSelection {
        (self ?? .thisMacEmpty).resolved(in: catalog, previous: previous)
    }
}

extension RunnerCatalog {
    func contains(_ id: RunnerItem.ID) -> Bool {
        item(id) != nil
    }

    func item(_ id: RunnerItem.ID) -> RunnerItem? {
        thisMac.first { $0.id == id } ?? otherMachines.first { $0.id == id }
    }
}

/// The local runner detail's tabs: Output and Configuration, and Jobs for a VM runner.
enum DetailTab: String, CaseIterable, Sendable {
    case output
    case configuration
    case jobs

    var title: String {
        switch self {
        case .output: return "Output"
        case .configuration: return "Configuration"
        case .jobs: return "Jobs"
        }
    }

    /// The tabs a runner offers, in order.
    static func tabs(isVM: Bool) -> [DetailTab] {
        isVM ? [.output, .configuration, .jobs] : [.output, .configuration]
    }

    /// This tab, or Output when the runner has no such tab (a saved Jobs tab on a host runner).
    func shown(isVM: Bool) -> DetailTab {
        Self.tabs(isVM: isVM).contains(self) ? self : .output
    }
}
