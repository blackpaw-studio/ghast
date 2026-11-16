import Foundation

/// Where a self-hosted runner is registered: one repository, or a whole organization.
/// Supplies the REST path prefix and the `config.sh --url` for that level.
enum RunnerScope: Hashable, Sendable {
    case repository(fullName: String)
    case organization(login: String)

    private static let gitHubHost = "github.com"

    /// `/repos/{owner}/{repo}` or `/orgs/{login}`.
    var apiPathPrefix: String {
        switch self {
        case .repository(let fullName): "/repos/\(fullName)"
        case .organization(let login): "/orgs/\(login)"
        }
    }

    /// The URL `config.sh --url` registers against.
    var configURL: String {
        "https://\(Self.gitHubHost)/\(displayName)"
    }

    /// Repository full name or organization login.
    var displayName: String {
        switch self {
        case .repository(let fullName): fullName
        case .organization(let login): login
        }
    }

    var isOrganization: Bool {
        if case .organization = self { return true }
        return false
    }

    /// Maps a runner's `gitHubUrl` (from its `.runner` file) to a scope:
    /// `https://github.com/{org}` → organization, `https://github.com/{owner}/{repo}[/…]` → repository.
    /// Returns nil for other hosts or a URL with no path.
    init?(gitHubURL: String) {
        guard let url = URL(string: gitHubURL),
              url.host?.lowercased() == Self.gitHubHost else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        switch components.count {
        case 0: return nil
        case 1: self = .organization(login: components[0])
        default: self = .repository(fullName: "\(components[0])/\(components[1])")
        }
    }
}

// Explicit `{"kind": …, "name": …}` coding so the persisted shape doesn't depend on
// Swift's synthesized enum encoding.
extension RunnerScope: Codable {
    private enum CodingKeys: String, CodingKey { case kind, name }
    private enum Kind: String, Codable { case repository, organization }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .repository: self = .repository(fullName: name)
        case .organization: self = .organization(login: name)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isOrganization ? Kind.organization : .repository, forKey: .kind)
        try container.encode(displayName, forKey: .name)
    }
}

extension GitHubRepository {
    var runnerScope: RunnerScope { .repository(fullName: fullName) }
}
