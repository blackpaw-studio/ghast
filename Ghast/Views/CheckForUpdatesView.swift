import SwiftUI
import Sparkle

struct CheckForUpdatesView: View {
    @State private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater
    
    init(updater: SPUUpdater) {
        self.updater = updater
        _checkForUpdatesViewModel = State(initialValue: CheckForUpdatesViewModel(updater: updater))
    }
    
    var body: some View {
        Button("Check for Updates...", action: updater.checkForUpdates)
            .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

@MainActor
@Observable
final class CheckForUpdatesViewModel {
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var observation: NSKeyValueObservation?
    
    init(updater: SPUUpdater) {
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let canCheck = change.newValue ?? false
            Task { @MainActor [weak self] in self?.canCheckForUpdates = canCheck }
        }
    }
}
