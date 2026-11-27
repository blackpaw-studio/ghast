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
    /// The guest sends at most 4 KB of values; a longer line is not Ghast's and is never decoded.
    static let maxMarkerBytes = markerPrefix.utf8.count + 4096

    static func validated(_ raw: [String: String], scope: RunnerScope) -> GuestRunInfo {
        GuestRunInfo(
            repository: raw["repository"].flatMap { validRepository($0, scope: scope) },
            workflowName: raw["workflow"].flatMap(JobText.clean),
            runID: raw["run_id"].flatMap(positiveInt),
            runAttempt: raw["run_attempt"].flatMap(positiveInt)
        )
    }

    static func isMarker(_ text: String) -> Bool { text.hasPrefix(markerPrefix) }

    /// The only keys a marker may carry; any other is ignored without being decoded.
    private static let markerKeys: Set<Substring> = ["repository", "workflow", "run_id", "run_attempt"]

    /// Reads a `ghast: run-info key=<base64> …` line; nil when it isn't one. Any marker gives
    /// a result, so the first one can be locked in: a line over `maxMarkerBytes` has no values
    /// (nothing in it is decoded), and a field that doesn't decode is dropped on its own.
    static func parseMarker(_ text: String) -> [String: String]? {
        guard text.hasPrefix(markerPrefix) else { return nil }
        guard text.utf8.count <= maxMarkerBytes else { return [:] }
        var values: [String: String] = [:]
        for pair in text.dropFirst(markerPrefix.count).split(separator: " ") {
            guard let equals = pair.firstIndex(of: "="), markerKeys.contains(pair[..<equals]),
                  let data = Data(base64Encoded: String(pair[pair.index(after: equals)...]))
            else { continue }
            // A guest in the C locale clips by bytes, which can cut a character: decode leniently.
            values[String(pair[..<equals])] = String(decoding: data, as: UTF8.self)
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
