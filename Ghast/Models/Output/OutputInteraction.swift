import Foundation

/// The Output tab's find bar: case-insensitive matches across the visible lines, and which one
/// is current. Pure, so the view only renders it.
struct OutputFindModel: Equatable, Sendable {
    struct Match: Equatable, Sendable {
        let lineID: Int
        /// Character offsets into the line's text.
        let range: Range<Int>
    }

    private(set) var query = ""
    private(set) var matches: [Match] = []
    private(set) var currentIndex: Int?

    var current: Match? { currentIndex.map { matches[$0] } }

    /// "3 of 12", "No matches", or nothing while the query is empty.
    var matchCountText: String {
        guard !query.isEmpty else { return "" }
        guard let currentIndex else { return "No matches" }
        return "\(currentIndex + 1) of \(matches.count)"
    }

    /// Recomputes the matches. The current match stays current while it still exists, so new
    /// output arriving doesn't move the user's place.
    mutating func update(query: String, lines: [OutputLine]) {
        let previous = current
        self.query = query
        matches = query.isEmpty ? [] : lines.flatMap { line in
            Self.ranges(of: query, in: line.text).map { Match(lineID: line.id, range: $0) }
        }
        if matches.isEmpty {
            currentIndex = nil
        } else if let previous, let kept = matches.firstIndex(of: previous) {
            currentIndex = kept
        } else {
            currentIndex = min(currentIndex ?? 0, matches.count - 1)
        }
    }

    mutating func next() { step(by: 1) }

    mutating func previous() { step(by: -1) }

    private mutating func step(by offset: Int) {
        guard let currentIndex, !matches.isEmpty else { return }
        self.currentIndex = (currentIndex + offset + matches.count) % matches.count
    }

    private static func ranges(of query: String, in text: String) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var searchStart = text.startIndex
        while let found = text.range(of: query, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            let lower = text.distance(from: text.startIndex, to: found.lowerBound)
            result.append(lower..<(lower + text.distance(from: found.lowerBound, to: found.upperBound)))
            searchStart = found.upperBound
        }
        return result
    }
}

/// Whether the Output tab sticks to the newest line.
struct FollowState: Equatable, Sendable {
    private(set) var isFollowing = true
    /// Bumped whenever the view should jump to the end.
    private(set) var jumpRequest = 0

    /// The user moved the scroll position: anywhere but the end stops following.
    mutating func userScrolled(isAtEnd: Bool) {
        if !isAtEnd { isFollowing = false }
    }

    /// The Follow button or ⌥⌘↓.
    mutating func follow() {
        isFollowing = true
        jumpRequest += 1
    }
}

extension OutputLine {
    /// "10:08:15  Running job: build-and-notarize", one line each, for Copy All Output.
    static func copyText(_ lines: [OutputLine]) -> String {
        lines.map { $0.clockText.isEmpty ? $0.text : "\($0.clockText)  \($0.text)" }.joined(separator: "\n")
    }
}
