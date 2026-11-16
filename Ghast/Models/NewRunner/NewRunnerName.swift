import Foundation

/// The rules for a new runner's name: the suggestion, validation and the Create button. Pure.
///
/// A runner's folder is named after the runner (`~/.ghast/runners/{name}`), so a name is taken
/// by any runner on this Mac, whatever its scope, as well as by any runner GitHub lists in the
/// chosen scope.
enum NewRunnerName {
    static let maxLength = 64
    private static let fallbackHost = "mac"

    enum Validation: Equatable, Sendable {
        case valid
        /// Nothing typed yet: Create is disabled, with no message.
        case empty
        case invalidCharacters
        /// GitHub or this Mac already has a runner with this name in the scope.
        case clash
        /// A runner on this Mac in another scope already uses the name (and its folder).
        case takenOnThisMac

        /// The inline red message, if any. Callers pass the name through `validate` first.
        func message(scope: RunnerScope, name: String) -> String? {
            switch self {
            case .valid, .empty: nil
            case .invalidCharacters: "Use up to \(NewRunnerName.maxLength) letters, numbers, hyphens, underscores or periods."
            case .clash: "A runner named \(name) already exists in \(scope.displayName)."
            case .takenOnThisMac: "A runner named \(name) already exists on this Mac."
            }
        }
    }

    /// `{host}-{n}`, where n is one more than this Mac's runners in `scope`, bumped until the
    /// name is free.
    static func suggested(hostName: String, scope: RunnerScope, localRunners: [LocalRunner], gitHubNames: [String]) -> String {
        let host = slug(hostName)
        let start = localRunners.filter { $0.scope == scope }.count + 1
        let taken = takenNames(localRunners: localRunners, gitHubNames: gitHubNames)
        let n = (start...).first { !taken.contains("\(host)-\($0)".lowercased()) } ?? start
        return "\(host)-\(n)"
    }

    static func validate(_ name: String, scope: RunnerScope, localRunners: [LocalRunner], gitHubNames: [String]) -> Validation {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard isSafe(name) else { return .invalidCharacters }
        let key = name.lowercased()
        let inScope = gitHubNames.map { $0.lowercased() } + localRunners.filter { $0.scope == scope }.map { $0.name.lowercased() }
        if inScope.contains(key) { return .clash }
        if localRunners.contains(where: { $0.name.lowercased() == key }) { return .takenOnThisMac }
        return .valid
    }

    static func canCreate(name: String, scope: RunnerScope?, localRunners: [LocalRunner], gitHubNames: [String]) -> Bool {
        guard let scope else { return false }
        return validate(name, scope: scope, localRunners: localRunners, gitHubNames: gitHubNames) == .valid
    }

    /// Letters, digits, `-`, `_` and `.`; not starting with `.` (a hidden folder) and no `..`.
    private static func isSafe(_ name: String) -> Bool {
        guard name.count <= maxLength, !name.hasPrefix("."), !name.contains("..") else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar))
        }
    }

    /// "Evan’s MacBook Pro" → "evan-s-macbook-pro".
    private static func slug(_ hostName: String) -> String {
        let words = hostName.lowercased().split { character in
            !(character.isASCII && (character.isLetter || character.isNumber))
        }
        let slug = words.joined(separator: "-")
        return slug.isEmpty ? fallbackHost : slug
    }

    private static func takenNames(localRunners: [LocalRunner], gitHubNames: [String]) -> Set<String> {
        Set(localRunners.map { $0.name.lowercased() } + gitHubNames.map { $0.lowercased() })
    }
}
