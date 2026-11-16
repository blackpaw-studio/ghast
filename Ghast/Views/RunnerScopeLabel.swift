import SwiftUI

/// Names where a runner is registered. A repository shows its full name as plain text
/// (styled by the caller's font and foreground style); an organization shows its login
/// followed by a small "Org" badge.
struct RunnerScopeLabel: View {
    let scope: RunnerScope

    var body: some View {
        switch scope {
        case .repository(let fullName):
            Text(fullName)
        case .organization(let login):
            HStack(spacing: 6) {
                Text(login)
                OrganizationBadge()
            }
        }
    }
}

/// Small capsule marking something as organization-level.
struct OrganizationBadge: View {
    var body: some View {
        Label("Org", systemImage: "building.2")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.purple)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.purple.opacity(0.12))
                    .overlay(Capsule().stroke(Color.purple.opacity(0.3), lineWidth: 1))
            )
            .fixedSize()
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        RunnerScopeLabel(scope: .repository(fullName: "octo/ghast"))
        RunnerScopeLabel(scope: .organization(login: "acme"))
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding()
}
