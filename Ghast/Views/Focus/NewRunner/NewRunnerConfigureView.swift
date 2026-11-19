import SwiftUI
import os

/// New Runner, step one: where the runner goes, its name and labels.
struct NewRunnerConfigureView: View {
    let initialCustomLabels: [String]
    let tartLocator: TartLocator
    let xcodeVersions: any TartXcodeVersionProviding
    let create: (NewRunnerRequest) -> Void
    let cancel: () -> Void

    @Environment(RunnerService.self) private var runnerService
    @Environment(RemoteRunnerStore.self) private var remoteStore
    @Environment(RepositoryCatalog.self) private var repositoryCatalog
    @Environment(GitHubAuthService.self) private var authService
    @Environment(\.gitHubAPIService) private var api
    @Environment(\.focusContext) private var context
    @Environment(\.openSettings) private var openSettings

    @State private var scope: RunnerScope?
    @State private var name = ""
    @State private var isNameEdited = false
    @State private var labels: LabelTokenList?
    @State private var fetchedNames: [RunnerScope: [String]] = [:]
    @State private var runnerGroups: [GitHubRunnerGroup] = []
    @State private var runnerGroup: String?
    @State private var workFolder = LocalRunner.defaultWorkFolder
    @State private var isAdvancedExpanded = false
    @State private var avatars = ScopeAvatarImages()
    @State private var runIn: NewRunnerRunIn
    /// nil until the locator has answered.
    @State private var tartInstallation: TartInstallation?
    /// The exact image ref; empty while the newest Xcode release is still being looked up.
    @State private var tartImage = ""
    @FocusState private var isNameFocused: Bool

    init(
        initialCustomLabels: [String],
        initialRunIn: NewRunnerRunIn = .thisMac,
        initialTartInstallation: TartInstallation? = nil,
        tartLocator: TartLocator,
        xcodeVersions: any TartXcodeVersionProviding = FallbackXcodeVersionProvider(),
        create: @escaping (NewRunnerRequest) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.initialCustomLabels = initialCustomLabels
        self.tartLocator = tartLocator
        self.xcodeVersions = xcodeVersions
        self.create = create
        self.cancel = cancel
        _runIn = State(initialValue: initialRunIn)
        _tartInstallation = State(initialValue: initialTartInstallation)
    }

    private static let logger = Logger(subsystem: "net.evancoleman.ghast", category: "new-runner")

    private var choices: NewRunnerScopeChoices {
        NewRunnerScopeChoices(organizations: remoteStore.adminOrganizations, repositories: repositoryCatalog.repositories ?? [])
    }

    /// No repository list yet and none has failed: the first load is still on its way.
    private var isLoadingRepositories: Bool {
        guard repositoryCatalog.repositories == nil else { return false }
        if case .failed = repositoryCatalog.status { return false }
        return true
    }

    /// Why the repositories didn't load, while there is no list to show instead.
    private var repositoryFailure: String? {
        guard repositoryCatalog.repositories == nil, case let .failed(message) = repositoryCatalog.status else { return nil }
        return message
    }

    private var tokens: LabelTokenList {
        labels ?? LabelTokenList(architecture: context.hostInfo.architecture, custom: initialCustomLabels)
    }

    /// Runner names GitHub lists in `scope`: the main window's last fetch, or this sheet's own.
    private func gitHubNames(in scope: RunnerScope) -> [String] {
        if let names = fetchedNames[scope] { return names }
        switch remoteStore.fetches[scope] {
        case let .loaded(runners, _)?: return runners.map(\.name)
        case let .failed(_, lastGood)?: return lastGood?.runners.map(\.name) ?? []
        case nil: return []
        }
    }

    private var validation: NewRunnerName.Validation? {
        scope.map { NewRunnerName.validate(name, scope: $0, localRunners: runnerService.localRunners, gitHubNames: gitHubNames(in: $0)) }
    }

    private var isTartUsable: Bool { tartInstallation?.isUsable == true }

    private var selectedImage: String { tartImage.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isRunInValid: Bool {
        switch runIn {
        case .thisMac: true
        case .tartVM: isTartUsable && !selectedImage.isEmpty
        }
    }

    private var canCreate: Bool {
        isRunInValid
            && choices.choice(for: scope) != nil
            && NewRunnerName.canCreate(name: name, scope: scope, localRunners: runnerService.localRunners, gitHubNames: scope.map(gitHubNames) ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Runner").font(FocusType.title2)
            Text(runIn == .tartVM
                 ? "Ghast starts a fresh Tart VM for each job and deletes it afterwards."
                 : "Ghast downloads the GitHub Actions runner, registers it, and starts it on this Mac.")
                .font(FocusType.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, FocusMetrics.sheetTitleGap)
            form.padding(.top, FocusMetrics.sheetBodyToBox)
            help.padding(.top, FocusMetrics.sheetHelpTop)
            tartNotice.padding(.top, FocusMetrics.sheetHelpTop)
            advanced.padding(.top, FocusMetrics.sheetAdvancedTop)
            footer.padding(.top, FocusMetrics.sheetFooterTop)
        }
        .task { await repositoryCatalog.load(account: authService.currentUser?.login) }
        .task(id: scope) { await loadScopeDetails() }
        .task { if tartInstallation == nil { await detectTart() } }
        .onAppear {
            isNameFocused = true
            if scope == nil { choose(choices.first?.scope) }
        }
        .onChange(of: choices) { _, new in
            avatars.load(new.all)
            // A refresh can drop the chosen repository (admin access removed).
            if new.choice(for: scope) == nil { choose(new.first?.scope) }
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(spacing: 0) {
            row("Add to") {
                HStack(spacing: FocusMetrics.formCaptionGap) {
                    Spacer(minLength: 0)
                    if isLoadingRepositories {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Loading repositories")
                    }
                    // Sized to its widest item, like NewRunner.png, until that no longer fits the
                    // column; then it takes the column and truncates the chosen name.
                    ViewThatFits(in: .horizontal) {
                        scopePicker.fixedSize()
                        scopePicker
                    }
                }
            }
            FocusFormDivider()
            row("Run in") {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Picker("Run in", selection: $runIn) {
                        Text(NewRunnerRunIn.thisMac.title).tag(NewRunnerRunIn.thisMac)
                        Text(NewRunnerRunIn.tartVM.title).tag(NewRunnerRunIn.tartVM).disabled(!isTartUsable)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if runIn == .tartVM { imageRows }
            FocusFormDivider()
            row("Name") {
                TextField("Name", text: nameBinding, prompt: Text("Runner name"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .focused($isNameFocused)
            }
            FocusFormDivider()
            if runIn == .tartVM {
                row("Workflow") { RunsOnLine(runnerName: name.trimmingCharacters(in: .whitespacesAndNewlines)) }
            } else {
                row("Labels") {
                    LabelTokenField(labels: Binding(get: { tokens }, set: { labels = $0 }))
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: FocusMetrics.formBoxRadius, style: .continuous)
                .fill(FocusColor.group)
        )
    }

    @ViewBuilder
    private var imageRows: some View {
        FocusFormDivider()
        TartImagePicker(image: $tartImage, versions: xcodeVersions, autoPicksNewest: true) { label, value in
            row(label) { value }
        }
    }

    /// Why the Tart VM option is off, and the command that fixes it.
    @ViewBuilder
    private var tartNotice: some View {
        if let installation = tartInstallation, !installation.isUsable {
            let (message, command) = Self.remedy(for: installation)
            HStack(alignment: .firstTextBaseline, spacing: FocusMetrics.formCaptionGap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(message).font(FocusType.subheadline).foregroundStyle(.secondary)
                    Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .buttonStyle(.link)
                .font(FocusType.subheadline)
            }
            .padding(.horizontal, FocusMetrics.formRowInset)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func remedy(for installation: TartInstallation) -> (message: String, command: String) {
        switch installation {
        case let .tooOld(_, version):
            ("Tart VM needs Tart \(TartLocator.minimumVersion) or later; \(version) is installed. Reinstall it with:", TartInstallation.reinstallCommand)
        case .missing, .found:
            ("Tart VM needs Tart, which isn't installed. Install it with:", TartInstallation.installCommand)
        }
    }

    private func detectTart() async {
        let installation = await tartLocator.locate()
        tartInstallation = installation
        if !installation.isUsable { runIn = .thisMac }
    }

    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(FocusType.body)
                .frame(width: FocusMetrics.newRunnerLabelColumn, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, FocusMetrics.formRowInset)
        .frame(minHeight: FocusMetrics.formRowHeight)
    }

    private var scopePicker: some View {
        Picker("Add to", selection: scopeMenuBinding) {
            if !choices.organizations.isEmpty {
                Section("Organizations") {
                    ForEach(choices.organizations) { scopeItem($0) }
                }
            }
            if !choices.repositories.isEmpty {
                Section("Repositories") {
                    ForEach(choices.repositories) { scopeItem($0) }
                }
            } else if isLoadingRepositories {
                Section("Repositories") {
                    Text("Loading Repositories…").tag(ScopeMenuItem.loading).disabled(true)
                }
            } else if repositoryFailure != nil {
                Section("Repositories") {
                    Text("Couldn't Load Repositories").tag(ScopeMenuItem.loadFailed).disabled(true)
                    Text("Try Again").tag(ScopeMenuItem.retry)
                }
            }
            if authService.needsScopeUpgrade {
                Divider()
                Text("Organizations need more access").tag(ScopeMenuItem.note).disabled(true)
                Text("Grant Access in Settings…").tag(ScopeMenuItem.grantAccess)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private func scopeItem(_ choice: NewRunnerScopeChoice) -> some View {
        Label {
            Text(choice.name) + Text(" \(choice.kind)").foregroundStyle(.secondary)
        } icon: {
            Image(nsImage: avatars.image(for: choice))
        }
        .tag(ScopeMenuItem.scope(choice.scope))
    }

    @ViewBuilder
    private var help: some View {
        if let scope, let message = validation?.message(scope: scope, name: name) {
            Text(message)
                .font(FocusType.callout)
                .foregroundStyle(.red)
                .padding(.horizontal, FocusMetrics.formRowInset)
        } else if let failure = repositoryFailure {
            HStack(alignment: .firstTextBaseline, spacing: FocusMetrics.formCaptionGap) {
                Text("Couldn't load repositories.")
                    .foregroundStyle(.secondary)
                    .help(failure)
                Button("Try Again", action: retryRepositories)
                    .buttonStyle(.link)
            }
            .font(FocusType.subheadline)
            .padding(.horizontal, FocusMetrics.formRowInset)
        } else {
            Text(scope.map { "Names must be unique in \($0.displayName). Default labels are added for you." }
                 ?? "Default labels are added for you.")
                .font(FocusType.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, FocusMetrics.formRowInset)
        }
    }

    // MARK: Advanced

    private var advanced: some View {
        DisclosureGroup(isExpanded: $isAdvancedExpanded) {
            VStack(spacing: 0) {
                if runIn == .thisMac {
                    row("Architecture") {
                        Picker("Architecture", selection: architectureBinding) {
                            ForEach(HostArchitecture.allCases, id: \.self) { Text($0.runnerLabel).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                    FocusFormDivider()
                }
                if scope?.isOrganization == true {
                    row("Runner group") {
                        Picker("Runner group", selection: $runnerGroup) {
                            ForEach(runnerGroups, id: \.name) { Text($0.name).tag(Optional($0.name)) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .disabled(runnerGroups.isEmpty)
                    }
                    FocusFormDivider()
                }
                row("Work folder") {
                    TextField("Work folder", text: $workFolder)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
            }
            .background(
                RoundedRectangle(cornerRadius: FocusMetrics.formBoxRadius, style: .continuous)
                    .fill(FocusColor.group)
            )
            .padding(.top, FocusMetrics.formHelpTop)
            if runIn == .thisMac && tokens.architecture == .x64 && context.hostInfo.architecture == .arm64 {
                Text("X64 runners run under Rosetta.")
                    .font(FocusType.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, FocusMetrics.formRowInset)
                    .padding(.top, FocusMetrics.sheetHelpTop)
            }
        } label: {
            HStack(spacing: FocusMetrics.formCaptionGap) {
                Text("Advanced").font(FocusType.body)
                Text(runIn == .tartVM ? "Runner group, work folder" : "Architecture, runner group, work folder")
                    .font(FocusType.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: FocusMetrics.sheetButtonSpacing) {
            Spacer()
            Button("Cancel", role: .cancel, action: cancel)
                .keyboardShortcut(.cancelAction)
            Button("Create Runner", action: submit)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate || workFolder.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }

    private func submit() {
        guard canCreate, let scope else { return }
        let group = scope.isOrganization ? runnerGroups.first { $0.name == runnerGroup } : nil
        create(NewRunnerRequest(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            scope: scope,
            // VMs are Apple Silicon guests.
            labels: runIn == .tartVM ? tokens.with(architecture: .arm64) : tokens,
            // The default group needs no `--runnergroup`.
            runnerGroup: group.flatMap { $0.isDefault ? nil : $0.name },
            workFolder: workFolder.trimmingCharacters(in: .whitespaces),
            backend: runIn == .tartVM ? .tart(image: selectedImage) : .host
        ))
    }

    // MARK: State

    private enum ScopeMenuItem: Hashable {
        case scope(RunnerScope)
        case note
        case grantAccess
        case loading
        case loadFailed
        case retry
    }

    private var scopeMenuBinding: Binding<ScopeMenuItem> {
        Binding(
            get: {
                if let scope { return .scope(scope) }
                if isLoadingRepositories { return .loading }
                return repositoryFailure == nil ? .note : .loadFailed
            },
            set: { item in
                switch item {
                case let .scope(new): choose(new)
                case .grantAccess: openSettings()
                case .retry: retryRepositories()
                case .note, .loading, .loadFailed: break
                }
            }
        )
    }

    private var nameBinding: Binding<String> {
        Binding(get: { name }, set: { name = $0; isNameEdited = true })
    }

    private var architectureBinding: Binding<HostArchitecture> {
        Binding(get: { tokens.architecture }, set: { labels = tokens.with(architecture: $0) })
    }

    private func choose(_ new: RunnerScope?) {
        guard new != scope else { return }
        scope = new
        suggestName()
    }

    /// Fills in `{host}-{n}` until the user types a name of their own.
    private func suggestName() {
        guard !isNameEdited, let scope else { return }
        name = NewRunnerName.suggested(
            hostName: context.hostInfo.computerName,
            scope: scope,
            localRunners: runnerService.localRunners,
            gitHubNames: gitHubNames(in: scope)
        )
    }

    private func retryRepositories() {
        let account = authService.currentUser?.login
        Task { await repositoryCatalog.retry(account: account) }
    }

    /// The scope's runner names (for clashes) and, for organizations, its runner groups.
    private func loadScopeDetails() async {
        guard let scope else { return }
        do {
            let runners = try await api.fetchRunners(in: scope)
            fetchedNames[scope] = runners.map(\.name)
            suggestName()
        } catch {
            if !error.isCancellation {
                Self.logger.error("Couldn't list runners in \(scope.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        guard case let .organization(login) = scope else {
            runnerGroups = []
            runnerGroup = nil
            return
        }
        do {
            let groups = try await api.fetchRunnerGroups(org: login)
            guard self.scope == scope else { return }
            runnerGroups = groups
            runnerGroup = (groups.first(where: \.isDefault) ?? groups.first)?.name
        } catch {
            if !error.isCancellation {
                Self.logger.error("Couldn't list runner groups in \(login, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
