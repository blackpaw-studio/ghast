import Foundation

/// Text from a job or workflow name: control characters out, clipped, nil when nothing is left.
enum JobText {
    static let maxLength = 200

    static func clean(_ text: String) -> String? {
        let kept = String(String.UnicodeScalarView(text.unicodeScalars.filter { !$0.properties.generalCategory.isControl }))
        let clipped = String(kept.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        return clipped.isEmpty ? nil : clipped
    }
}

private extension Unicode.GeneralCategory {
    var isControl: Bool { self == .control || self == .lineSeparator || self == .paragraphSeparator }
}

/// What the guest's job-started hook reported about the run. The workflow controls the guest,
/// so every field is untrusted: `validated` drops each one that fails its check.
struct GuestRunInfo: Sendable, Equatable {
    var repository: String?
    var workflowName: String?
    var runID: Int?
    var runAttempt: Int?

    static let markerPrefix = "ghast: run-info "

    static func validated(_ raw: [String: String], scope: RunnerScope) -> GuestRunInfo {
        GuestRunInfo(
            repository: raw["repository"].flatMap { validRepository($0, scope: scope) },
            workflowName: raw["workflow"].flatMap(JobText.clean),
            runID: raw["run_id"].flatMap(positiveInt),
            runAttempt: raw["run_attempt"].flatMap(positiveInt)
        )
    }

    /// Reads a `ghast: run-info key=<base64> …` line; nil when it isn't one. A value that
    /// isn't valid base64 or UTF-8 ends the line's parse as nil.
    static func parseMarker(_ text: String) -> [String: String]? {
        guard text.hasPrefix(markerPrefix) else { return nil }
        var values: [String: String] = [:]
        for pair in text.dropFirst(markerPrefix.count).split(separator: " ") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            guard let data = Data(base64Encoded: String(pair[pair.index(after: equals)...])),
                  let value = String(data: data, encoding: .utf8) else { return nil }
            values[String(pair[..<equals])] = value
        }
        return values
    }

    private static func validRepository(_ value: String, scope: RunnerScope) -> String? {
        guard value.wholeMatch(of: #/[A-Za-z0-9-]+\/[A-Za-z0-9._-]+/#) != nil else { return nil }
        let owner = value.split(separator: "/")[0]
        switch scope {
        case .organization(let login):
            return owner.caseInsensitiveCompare(login) == .orderedSame ? value : nil
        case .repository(let fullName):
            return value.caseInsensitiveCompare(fullName) == .orderedSame ? value : nil
        }
    }

    private static func positiveInt(_ text: String) -> Int? {
        guard let number = Int(text), number > 0 else { return nil }
        return number
    }
}

private extension Substring {
    func caseInsensitiveCompare(_ other: String) -> ComparisonResult {
        String(self).caseInsensitiveCompare(other)
    }
}
