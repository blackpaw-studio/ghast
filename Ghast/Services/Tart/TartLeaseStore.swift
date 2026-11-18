import Foundation

/// What Ghast made for one VM clone, kept so a crash or force-quit can be cleaned up next launch.
struct TartLease: Codable, Equatable, Sendable {
    /// The Ghast runner (`LocalRunner.id`) the clone served.
    let runnerID: String
    /// The just-in-time runner's id on GitHub, once registered.
    var jitRunnerID: Int?
    let scope: RunnerScope
}

/// Persists `[clone name: lease]` in UserDefaults. Main-actor use only: it reads, changes and
/// writes the whole table.
struct TartLeaseStore {
    static let key = "tartLeases"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func all() -> [String: TartLease] {
        guard let data = defaults.data(forKey: Self.key),
              let leases = try? JSONDecoder().decode([String: TartLease].self, from: data)
        else { return [:] }
        return leases
    }

    func record(_ lease: TartLease, forClone clone: String) {
        update { $0[clone] = lease }
    }

    func setJITRunnerID(_ id: Int, forClone clone: String) {
        update { $0[clone]?.jitRunnerID = id }
    }

    func remove(clone: String) {
        update { $0.removeValue(forKey: clone) }
    }

    private func update(_ change: (inout [String: TartLease]) -> Void) {
        var leases = all()
        change(&leases)
        if let data = try? JSONEncoder().encode(leases) { defaults.set(data, forKey: Self.key) }
    }
}
