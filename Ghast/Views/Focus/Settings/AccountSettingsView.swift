import SwiftUI

/// Settings › Account: who is signed in, what Ghast may do, the organizations it can manage,
/// and Sign Out.
struct AccountSettingsView: View {
    @Environment(GitHubAuthService.self) private var authService
    @Environment(RemoteRunnerStore.self) private var remoteStore
    @Environment(\.appWindowRouter) private var router
    @State private var avatars = ScopeAvatarImages()
    @State private var isGranting = false
    @State private var isConfirmingSignOut = false

    var body: some View {
        SettingsPane {
            if let user = authService.currentUser, authService.isAuthenticated {
                signedIn(user)
            } else {
                signedOut
            }
        }
        .controlSize(.large)
        .sheet(isPresented: $isGranting, onDismiss: abandonUnfinishedGrant) {
            GrantAccessSheet(authService: authService, close: { isGranting = false })
        }
        .onChange(of: authService.signInState) { _, state in
            if state == .signedIn { isGranting = false }
        }
        .alert("Sign out of GitHub?", isPresented: $isConfirmingSignOut) {
            Button("Sign Out", role: .destructive) { authService.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Signing out doesn’t stop or remove runners on this Mac.")
        }
    }

    @ViewBuilder
    private func signedIn(_ user: GitHubUser) -> some View {
        AccountHeader(name: user.name ?? user.login)
            .frame(maxWidth: .infinity)

        FocusFormSection(caption: "Permissions") {
            PermissionRow(label: "Repositories", isGranted: true, grant: grant)
            FocusFormDivider()
            PermissionRow(label: "Organization runners", isGranted: !authService.needsScopeUpgrade, grant: grant)
        }

        FocusFormSection(caption: "Organizations You Administer") {
            let rows = organizationRows
            if rows.isEmpty {
                FocusFormRow(label: "None") { EmptyView() }
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.element.login) { index, row in
                if index > 0 { FocusFormDivider() }
                OrganizationRow(row: row, avatar: avatars.image(name: row.login, avatarURL: row.avatarURL))
            }
        }
        if !remoteStore.needsOwnerAccess.isEmpty {
            SettingsHelp(text: "Managing an organization's runners needs owner access. Ask an owner to make you one, or to add the runner.")
        }

        VStack(alignment: .leading, spacing: FocusMetrics.settingsSignOutHelpGap) {
            Button("Sign Out…") { isConfirmingSignOut = true }
            Text("Signing out doesn’t stop or remove runners on this Mac.")
                .font(FocusType.subheadline)
                .foregroundStyle(.secondary)
        }
        .task(id: organizationRows.map(\.avatarURL)) {
            avatars.load(avatarURLs: organizationRows.map(\.avatarURL))
        }
    }

    private var signedOut: some View {
        VStack(spacing: FocusMetrics.settingsSignOutHelpGap) {
            Text("Not signed in").font(FocusType.title2)
            Text("Sign in to add runners and see runners on other machines.")
                .font(FocusType.callout)
                .foregroundStyle(.secondary)
            Button("Sign In…") { router?.openMain() }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, FocusMetrics.settingsAvatarTop)
    }

    /// Administered organizations, then any GitHub refused (403/404) that aren't among them.
    private var organizationRows: [OrganizationRow.Model] {
        let administered = remoteStore.adminOrganizations.map {
            OrganizationRow.Model(login: $0.login, avatarURL: $0.avatarURL, needsOwnerAccess: remoteStore.needsOwnerAccess.contains($0.login))
        }
        let listed = Set(administered.map(\.login))
        let refused = remoteStore.needsOwnerAccess.subtracting(listed).sorted().map {
            OrganizationRow.Model(login: $0, avatarURL: "", needsOwnerAccess: true)
        }
        return administered + refused
    }

    private func grant() {
        isGranting = true
        Task { await authService.signIn() }
    }

    /// Closing the sheet abandons an attempt still in flight; the current token stays.
    private func abandonUnfinishedGrant() {
        if authService.signInState != .signedIn { authService.cancelSignIn() }
    }
}

/// The 64 pt initials disc, name and "Signed in to GitHub".
struct AccountHeader: View {
    let name: String

    var body: some View {
        VStack(spacing: 0) {
            Text(Self.initials(name))
                .font(.system(size: FocusMetrics.accountInitialsFontSize, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: FocusMetrics.accountAvatar, height: FocusMetrics.accountAvatar)
                .background(Circle().fill(Color.accentColor.opacity(FocusMetrics.accountAvatarFillOpacity)))
                .accessibilityHidden(true)
            Text(name)
                .font(FocusType.title2)
                .padding(.top, FocusMetrics.settingsNameTop)
            Text("Signed in to GitHub")
                .font(FocusType.callout)
                .foregroundStyle(.secondary)
                .padding(.top, FocusMetrics.settingsSignedInTop)
        }
        .padding(.top, FocusMetrics.settingsAvatarTop)
        .padding(.bottom, FocusMetrics.settingsAvatarBottom)
        .accessibilityElement(children: .combine)
    }

    /// "Evan Coleman" → "EC"; a single word gives its first letter.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        let letters = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
        return String(letters).uppercased()
    }
}

/// "Repositories  ✓ Granted" or "… ! Not granted [Grant…]".
struct PermissionRow: View {
    let label: String
    let isGranted: Bool
    let grant: () -> Void

    var body: some View {
        FocusFormRow(label: label, height: isGranted ? FocusMetrics.formRowHeight : FocusMetrics.settingsButtonRowHeight) {
            HStack(spacing: FocusMetrics.settingsStatusGlyphGap) {
                Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(isGranted ? .green : .orange)
                    .accessibilityHidden(true)
                Text(isGranted ? "Granted" : "Not granted")
                    .font(FocusType.body)
                    .foregroundStyle(.secondary)
            }
            if !isGranted {
                Button("Grant…", action: grant)
                    .padding(.leading, FocusMetrics.settingsGrantGap)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// An organization: 16 pt avatar and login, flagged when GitHub refused its runner list.
struct OrganizationRow: View {
    struct Model: Equatable {
        let login: String
        let avatarURL: String
        let needsOwnerAccess: Bool
    }

    let row: Model
    let avatar: NSImage

    var body: some View {
        HStack(spacing: FocusMetrics.settingsOrgAvatarGap) {
            Image(nsImage: avatar)
                .resizable()
                .frame(width: FocusMetrics.scopeAvatar, height: FocusMetrics.scopeAvatar)
                .accessibilityHidden(true)
            Text(row.login).font(FocusType.body)
            Spacer(minLength: 0)
            if row.needsOwnerAccess {
                Text("Needs owner access")
                    .font(FocusType.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, FocusMetrics.formRowInset)
        .frame(minHeight: FocusMetrics.settingsOrgRowHeight)
        .accessibilityElement(children: .combine)
    }
}
