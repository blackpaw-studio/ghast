import Foundation

/// The saved runner list in `UserDefaults`, read and written so that a record this build can't
/// decode (a newer build's, or a damaged one) is never lost: it is kept verbatim and written
/// back with every save. A stored value that isn't a list at all is never overwritten.
struct RunnerStore {
    static let key = "localRunners"

    private let defaults: UserDefaults
    /// Each undecodable record as JSON, exactly as it was stored (keys sorted).
    private var keptRecords: [Data] = []
    /// The stored value could not be read as a list; saving would destroy it.
    private var isUnreadable = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The `path` of every record kept aside, so discovery doesn't register its folder a second time.
    var keptPaths: Set<String> {
        Set(keptRecords.compactMap { record in
            (try? JSONSerialization.jsonObject(with: record) as? [String: Any])?["path"] as? String
        })
    }

    /// The readable runners. Replaces whatever a previous load kept aside.
    mutating func load() -> [LocalRunner] {
        keptRecords = []
        isUnreadable = false
        guard let stored = defaults.object(forKey: Self.key) else { return [] }
        guard let data = stored as? Data,
              let records = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            isUnreadable = true
            return []
        }

        var runners: [LocalRunner] = []
        for record in records {
            guard let bytes = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .fragmentsAllowed]) else {
                continue
            }
            if let runner = try? JSONDecoder().decode(LocalRunner.self, from: bytes) {
                runners.append(runner)
            } else {
                keptRecords.append(bytes)
            }
        }
        return runners
    }

    /// Writes `runners` plus every record kept aside. Does nothing if the stored value was unreadable.
    func save(_ runners: [LocalRunner]) throws {
        guard !isUnreadable else { return }
        let encoder = JSONEncoder()
        let pieces = try runners.map { try encoder.encode($0) } + keptRecords
        let list = Data("[".utf8) + Data(pieces.joined(separator: Data(",".utf8))) + Data("]".utf8)
        defaults.set(list, forKey: Self.key)
    }

    /// Forgets the records kept aside, for a deliberate reset.
    mutating func discardKeptRecords() {
        keptRecords = []
    }
}
