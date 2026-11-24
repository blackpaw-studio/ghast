import Foundation
import Observation

/// Settings › General › Cache: space used, the size cap and Clear Cache.
@MainActor
@Observable
final class CacheSettingsModel {
    private(set) var usage: CacheUsage?
    private(set) var errorMessage: String?
    /// Whether the Clear Cache confirmation is presented. SwiftUI clears it when the dialog
    /// closes, before the chosen button's action runs, so clearing doesn't read it.
    var isShowingClearConfirmation = false
    /// Set when the confirmation is asked for; the Clear action consumes it, Cancel drops it.
    @ObservationIgnored private var isClearRequested = false

    @ObservationIgnored private let stats: any CacheStatsProviding
    @ObservationIgnored private let settings: AppSettings

    init(stats: any CacheStatsProviding, settings: AppSettings) {
        self.stats = stats
        self.settings = settings
    }

    var capGB: Int { settings.cacheSizeCapGB }
    var usageText: String { Self.usageText(usage) }

    func refresh() async {
        usage = await stats.usage()
    }

    /// Saves the cap (at least 1 GB) and applies it now, removing the least recently used caches above it.
    func applyCap(_ gigabytes: Int) async {
        settings.cacheSizeCapGB = gigabytes
        await perform("apply the size cap") { try await stats.setCap(gigabytes: settings.cacheSizeCapGB) }
    }

    func requestClear() {
        isClearRequested = true
        isShowingClearConfirmation = true
    }

    func cancelClear() {
        isClearRequested = false
    }

    /// Clears the cache once per confirmation asked for; otherwise does nothing.
    func confirmClear() async {
        guard isClearRequested else { return }
        isClearRequested = false
        isShowingClearConfirmation = false
        await perform("clear the cache") { try await stats.clear() }
    }

    static func usageText(_ usage: CacheUsage?) -> String {
        guard let usage else { return "Checking…" }
        guard usage.entryCount > 0 else { return "Empty" }
        let size = ByteCountFormatter.string(fromByteCount: usage.totalBytes, countStyle: .file)
        return "\(size) in \(usage.entryCount) \(usage.entryCount == 1 ? "cache" : "caches")"
    }

    private func perform(_ action: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            errorMessage = nil
        } catch {
            errorMessage = "Ghast couldn’t \(action): \(error.localizedDescription)"
        }
        await refresh()
    }
}
