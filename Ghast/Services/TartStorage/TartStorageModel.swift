import Foundation
import Observation

/// Settings › General › Tart Storage: what Tart keeps on disk, and Remove / Remove Unused.
@MainActor
@Observable
final class TartStorageModel {
    private(set) var inventory = TartStorageInventory.empty
    private(set) var freeBytes: Int64?
    private(set) var hasLoaded = false
    /// A failed list, worded for the section; the last good inventory stays.
    private(set) var errorMessage: String?
    /// A failed or refused remove, by image id, shown on that row until the next remove of it.
    private(set) var rowErrors: [String: String] = [:]

    /// Whether the per-image confirmation is presented. SwiftUI clears it when the dialog closes,
    /// before the chosen button's action runs, so the action reads `removal` instead.
    var isShowingRemoveConfirmation = false
    var isShowingRemoveUnusedConfirmation = false
    /// The image the confirmation asked about. Remove consumes it, Cancel drops it.
    private(set) var removal: StoredImage?
    @ObservationIgnored private var isRemoveUnusedRequested = false
    @ObservationIgnored private var entries: [TartVMEntry] = []
    @ObservationIgnored private var lastPulling: Set<String> = []

    @ObservationIgnored private let cli: @Sendable () async throws -> any TartCLI
    @ObservationIgnored private let capacity: any HostCapacity
    @ObservationIgnored private let links: any TartCacheLinkReading
    @ObservationIgnored private let clock: any AppClock
    @ObservationIgnored private let usage: @MainActor () -> TartImageUsage

    init(
        cli: @escaping @Sendable () async throws -> any TartCLI,
        capacity: any HostCapacity,
        links: any TartCacheLinkReading = FileSystemTartCacheLinkReader(),
        clock: any AppClock,
        usage: @escaping @MainActor () -> TartImageUsage
    ) {
        self.cli = cli
        self.capacity = capacity
        self.links = links
        self.clock = clock
        self.usage = usage
    }

    // MARK: - Reading

    /// The image refs being pulled now; the view watches it to refresh when a pull ends.
    var pullingImages: Set<String> { usage().pullingImages }

    var headerText: String {
        guard hasLoaded else { return "Checking…" }
        let used = "Tart uses \(Self.gigabytes(inventory.totalBytes, rounding: .nearest)) GB"
        guard let freeBytes else { return used }
        return "\(used) · \(Self.gigabytes(freeBytes, rounding: .down)) GB free on this disk"
    }

    var canRemoveUnused: Bool { !inventory.unusedPulled.isEmpty }

    func refresh() async {
        do {
            entries = try await cli().list()
            errorMessage = nil
        } catch {
            errorMessage = "Ghast couldn’t read Tart’s images: \(error.localizedDescription)"
        }
        lastPulling = usage().pullingImages
        inventory = makeInventory()
        freeBytes = capacity.freeDiskBytes()
        hasLoaded = true
    }

    /// Refreshes when a pull has finished (the set shrank): the image just arrived.
    func pullsChanged(to pulling: Set<String>) async {
        let finished = !lastPulling.subtracting(pulling).isEmpty
        lastPulling = pulling
        if finished { await refresh() }
    }

    /// A row's size, in decimal GB like the header.
    func sizeText(_ image: StoredImage) -> String {
        "\(Self.gigabytes(image.sizeBytes, rounding: .nearest)) GB"
    }

    func lastUsedText(_ image: StoredImage) -> String {
        guard let accessed = image.accessed else { return "Never used" }
        let formatted = RelativeDateTimeFormatter().localizedString(for: accessed, relativeTo: clock.now())
        return "Last used \(formatted)"
    }

    // MARK: - Confirmations

    func requestRemove(_ image: StoredImage) {
        removal = image
        isShowingRemoveConfirmation = true
    }

    func requestRemoveUnused() {
        isRemoveUnusedRequested = true
        isShowingRemoveUnusedConfirmation = true
    }

    func cancelRemove() {
        removal = nil
        isRemoveUnusedRequested = false
    }

    func removalMessage(for image: StoredImage) -> String {
        var text = "Frees about \(Self.gigabytes(image.sizeBytes, rounding: .nearest)) GB."
        text += image.isLocal
            ? " This VM was made on this Mac and can't be downloaded again."
            : " It is downloaded again the next time a runner needs it."
        return text
    }

    var removeUnusedMessage: String {
        let unused = inventory.unusedPulled
        let total = unused.reduce(0) { $0 + $1.sizeBytes }
        let names = unused.map(\.displayName).joined(separator: "\n")
        return "\(names)\n\nFrees about \(Self.gigabytes(total, rounding: .nearest)) GB. Local VMs are never removed."
    }

    var removeUnusedTitle: String {
        let count = inventory.unusedPulled.count
        return "Remove \(count) unused \(count == 1 ? "image" : "images")?"
    }

    // MARK: - Removing

    /// Removes the image the confirmation asked about, once per request.
    func confirmRemove() async {
        guard let image = removal else { return }
        removal = nil
        isShowingRemoveConfirmation = false
        await delete([image])
    }

    /// Removes every pulled image nothing uses, in size order, once per request.
    func confirmRemoveUnused() async {
        guard isRemoveUnusedRequested else { return }
        isRemoveUnusedRequested = false
        isShowingRemoveUnusedConfirmation = false
        await delete(inventory.unusedPulled)
    }

    /// Deletes each image unless a runner has taken it since the list was read; a failure stays
    /// on its row and the rest carry on. The CLI is found first and the block reason is read
    /// again with no suspension before `delete`, so a runner can't take the image in between.
    private func delete(_ images: [StoredImage]) async {
        let tart: any TartCLI
        do {
            tart = try await cli()
        } catch {
            for image in images { rowErrors[image.id] = "Couldn’t remove it: \(error.localizedDescription)" }
            await refresh()
            return
        }
        for image in images {
            if let reason = currentBlockReason(of: image) {
                rowErrors[image.id] = reason
                continue
            }
            do {
                try await tart.delete(image.deleteRef)
                rowErrors[image.id] = nil
            } catch {
                rowErrors[image.id] = "Couldn’t remove it: \(error.localizedDescription)"
            }
        }
        await refresh()
    }

    /// The reason against today's runner usage, over the list as last read.
    private func currentBlockReason(of image: StoredImage) -> String? {
        let current = makeInventory()
        return (current.pulled + current.localVMs).first { $0.id == image.id }?.removeBlockReason
    }

    private func makeInventory() -> TartStorageInventory {
        let current = usage()
        return TartStorageInventory.make(
            entries: entries,
            digestForTag: { links.digest(forTag: $0) },
            runnerImages: current.runnerImages,
            pullingImages: current.pullingImages
        )
    }

    // MARK: - Formatting

    private enum Rounding { case nearest, down }

    private static func gigabytes(_ bytes: Int64, rounding: Rounding) -> Int64 {
        let unit: Int64 = 1_000_000_000
        return rounding == .down ? bytes / unit : (bytes + unit / 2) / unit
    }
}
