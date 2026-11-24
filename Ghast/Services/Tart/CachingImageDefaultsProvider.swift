import Foundation

/// Keeps each image's defaults for the session and shares a lookup that's already running.
/// A nil result isn't kept, so a first visit while offline doesn't stay on "Image default"
/// until relaunch.
actor CachingImageDefaultsProvider: TartImageDefaultsProviding {
    private let base: any TartImageDefaultsProviding
    private var results: [String: TartImageDefaults] = [:]
    private var inFlight: [String: Task<TartImageDefaults?, Never>] = [:]

    init(_ base: any TartImageDefaultsProviding) {
        self.base = base
    }

    func defaults(for image: String) async -> TartImageDefaults? {
        if let kept = results[image] { return kept }
        if let running = inFlight[image] { return await running.value }
        // Unstructured on purpose: a caller that is cancelled must not cancel the lookup the
        // others are waiting on.
        let lookup = Task { [base] in await base.defaults(for: image) }
        inFlight[image] = lookup
        let result = await lookup.value
        if inFlight[image] == lookup { inFlight[image] = nil }
        if let result { results[image] = result }
        return result
    }
}
