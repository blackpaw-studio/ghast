import Foundation

/// The labels a new runner gets: fixed defaults for its architecture, plus custom labels the
/// user types. Values only: every edit returns a new list.
struct LabelTokenList: Equatable, Sendable {
    /// An edit's result: the new list and the text left in the field.
    struct Edit: Equatable, Sendable {
        let tokens: LabelTokenList
        let remainder: String
    }

    static let separator: Character = ","
    private static let fixedDefaults = ["self-hosted", "macOS"]

    let architecture: HostArchitecture
    let custom: [String]

    init(architecture: HostArchitecture, custom: [String] = []) {
        self.architecture = architecture
        self.custom = custom
    }

    /// The labels the runner adds for itself; shown as fixed tokens.
    var defaults: [String] { Self.fixedDefaults + [architecture.runnerLabel] }
    var all: [String] { defaults + custom }

    func with(architecture: HostArchitecture) -> LabelTokenList {
        LabelTokenList(architecture: architecture, custom: custom)
    }

    /// Return: commits the text as one label. A rejected label stays in the field to fix;
    /// blank text just clears.
    func committing(_ text: String) -> Edit {
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return Edit(tokens: self, remainder: "") }
        guard accepts(label) else { return Edit(tokens: self, remainder: text) }
        return Edit(tokens: LabelTokenList(architecture: architecture, custom: custom + [label]), remainder: "")
    }

    /// Field text changed: each comma commits the text before it.
    func typing(_ text: String) -> Edit {
        var parts = text.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        let remainder = parts.removeLast()
        let tokens = parts.reduce(self) { tokens, part in tokens.committing(part).tokens }
        return Edit(tokens: tokens, remainder: remainder)
    }

    /// Removes a custom label; the defaults stay.
    func removing(_ label: String) -> LabelTokenList {
        LabelTokenList(architecture: architecture, custom: custom.filter { $0 != label })
    }

    /// The custom part of a saved label list (for `config.sh --labels`, which adds the defaults).
    static func customLabels(in labels: [String]) -> [String] {
        let defaults = Set((fixedDefaults + [HostArchitecture.arm64.runnerLabel, HostArchitecture.x64.runnerLabel]).map { $0.lowercased() })
        return labels.filter { !defaults.contains($0.lowercased()) }
    }

    private func accepts(_ label: String) -> Bool {
        guard !label.contains(where: \.isWhitespace), !label.contains(Self.separator) else { return false }
        return !all.contains { $0.caseInsensitiveCompare(label) == .orderedSame }
    }
}
