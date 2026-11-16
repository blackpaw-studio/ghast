import SwiftUI

/// Runner page for an organization the user administers. Mirrors the repository page:
/// org runners, local runners registered to the org, Add Runner and removal.
struct OrganizationDetailView: View {
    let organization: GitHubOrganization

    var body: some View {
        ScopedRunnersPanel(scope: .organization(login: organization.login)) { addRunner in
            header(addRunner: addRunner)
        }
    }

    private func header(addRunner: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            OrganizationAvatar(url: URL(string: organization.avatarURL))

            VStack(alignment: .leading, spacing: 6) {
                Text(organization.login)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)

                HStack(spacing: 8) {
                    Text("Organization runners")
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)

                    OrganizationBadge()
                }

                Text("Runners registered here can serve repositories in \(organization.login).")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            AddRunnerHeaderButton(action: addRunner)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Rectangle()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 24)
    }
}

/// The org's avatar in a 64 pt circle, over a gradient with `building.2` until it loads.
private struct OrganizationAvatar: View {
    let url: URL?
    private static let size: CGFloat = 64

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.purple, Color.blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "building.2")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white)
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
                .clipShape(Circle())
            }
        }
        .frame(width: Self.size, height: Self.size)
        .shadow(color: Color.purple.opacity(0.3), radius: 12, x: 0, y: 4)
    }
}

#Preview {
    OrganizationDetailView(organization: GitHubOrganization(login: "acme", id: 1, avatarURL: ""))
        .environment(RunnerService())
}
