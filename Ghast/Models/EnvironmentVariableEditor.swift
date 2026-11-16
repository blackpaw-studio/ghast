import Foundation

/// One editable environment variable row.
struct EnvironmentVariableDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }

    /// A row just added with +: not an error, and not saved.
    var isBlank: Bool { name.isEmpty && value.isEmpty }
}

enum EnvironmentVariableIssue: Equatable, Sendable {
    case invalidName
    case duplicateName

    var message: String {
        switch self {
        case .invalidName: return "Names start with a letter or underscore and use only letters, digits and underscores."
        case .duplicateName: return "Another variable already has this name."
        }
    }
}

/// The Configuration tab's environment variables: rows as typed, and the dictionary that is
/// safe to save. Names must match `^[A-Za-z_][A-Za-z0-9_]*$` and be unique; a row that breaks
/// either rule is shown with an error and left out of what is saved.
struct EnvironmentVariableEditor: Equatable, Sendable {
    var rows: [EnvironmentVariableDraft]

    init(rows: [EnvironmentVariableDraft]) {
        self.rows = rows
    }

    init(variables: [String: String]) {
        rows = variables
            .sorted { $0.key < $1.key }
            .map { EnvironmentVariableDraft(name: $0.key, value: $0.value) }
    }

    func issue(for row: EnvironmentVariableDraft) -> EnvironmentVariableIssue? {
        guard !row.isBlank else { return nil }
        guard Self.isValidName(row.name) else { return .invalidName }
        let first = rows.first { $0.name == row.name }
        return first?.id == row.id ? nil : .duplicateName
    }

    var savedVariables: [String: String] {
        var saved: [String: String] = [:]
        for row in rows where !row.isBlank && issue(for: row) == nil {
            saved[row.name] = row.value
        }
        return saved
    }

    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, isLetterOrUnderscore(first) else { return false }
        return name.unicodeScalars.allSatisfy { isLetterOrUnderscore($0) || ("0"..."9").contains($0) }
    }

    private static func isLetterOrUnderscore(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }
}

/// Runs the latest scheduled save once edits have been quiet for `delay`. The sleeper is
/// injected so tests never wait.
@MainActor
final class SaveDebouncer {
    private let sleeper: Sleeper
    private let delay: Duration
    private var generation = 0
    private var pending: (@MainActor () -> Void)?

    init(sleeper: @escaping Sleeper, delay: Duration = .milliseconds(500)) {
        self.sleeper = sleeper
        self.delay = delay
    }

    func schedule(_ save: @escaping @MainActor () -> Void) {
        generation += 1
        let scheduled = generation
        pending = save
        Task { [weak self, sleeper, delay] in
            try? await sleeper(delay)
            guard let self, self.generation == scheduled else { return }
            self.flush()
        }
    }

    /// Saves now (field commit, leaving the tab).
    func flush() {
        let save = pending
        pending = nil
        generation += 1
        save?()
    }
}
