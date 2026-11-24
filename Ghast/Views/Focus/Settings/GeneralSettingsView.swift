import AppKit
import SwiftUI

/// Settings › General: startup, menu bar and notifications, updates, VM isolation, the local
/// cache, and the runners folder.
struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(OpenAtLoginModel.self) private var openAtLogin
    @Environment(NotificationService.self) private var notifications
    @Environment(UpdateStatusModel.self) private var updates
    @Environment(RunnerService.self) private var runnerService
    @Environment(SoftnetHelperModel.self) private var softnetHelper
    @Environment(CacheSettingsModel.self) private var cache
    @Environment(\.focusContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(\.appVersion) private var appVersion

    @State private var isConfirmingHelperRemoval = false

    private static let notificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "net.evancoleman.ghast")"
    )

    var body: some View {
        @Bindable var settings = settings
        @Bindable var openAtLogin = openAtLogin
        @Bindable var updates = updates
        SettingsPane {
            FocusFormSection(caption: "Startup") {
                SettingsToggleRow(label: "Open Ghast at login", isOn: $openAtLogin.isOn)
                FocusFormDivider()
                SettingsToggleRow(label: "Restart runners that were running when Ghast quit", isOn: $settings.restartRunnersAtLaunch)
            }
            if openAtLogin.state == .needsApproval {
                SettingsHelp(text: "Allow Ghast in System Settings › General › Login Items.", buttonTitle: "Open") {
                    openAtLogin.openSystemSettings()
                }
            } else if let error = openAtLogin.errorMessage {
                SettingsHelp(text: "Ghast couldn’t change this: \(error)")
            }

            FocusFormSection(caption: "Menu Bar & Notifications") {
                SettingsToggleRow(label: "Show Ghast in the menu bar", isOn: $settings.showMenuBarExtra)
                FocusFormDivider()
                SettingsToggleRow(label: "Notify when a runner stops unexpectedly", isOn: notifyBinding(\.notifyUnexpectedStop))
                FocusFormDivider()
                SettingsToggleRow(label: "Notify when a job fails", isOn: notifyBinding(\.notifyJobFailure))
            }
            if notifications.authorization == .denied {
                SettingsHelp(text: "Notifications for Ghast are off in System Settings.", buttonTitle: "Open System Settings") {
                    Self.notificationSettingsURL.map { openURL($0) }
                }
            }

            FocusFormSection(caption: "Updates") {
                SettingsToggleRow(label: "Check for updates automatically", isOn: $updates.automaticallyChecks)
                FocusFormDivider()
                versionRow
            }

            FocusFormSection(caption: "VM Network Isolation") {
                FocusFormRow(label: "Isolation helper") {
                    Text(softnetHelper.status?.settingsText ?? "Checking…")
                        .font(FocusType.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                    if softnetHelper.status?.hasHelperFile == true {
                        Button("Remove Helper…") { isConfirmingHelperRemoval = true }
                            .disabled(softnetHelper.isWorking)
                    }
                }
            }
            if let message = softnetHelper.errorMessage {
                SettingsHelp(text: message)
            }
            SettingsHelp(text: "Runners with Isolate network on boot their VMs through a root-owned copy of softnet kept in /usr/local/libexec/ghast.")

            cacheSection

            FocusFormSection(caption: "Runners") {
                FocusFormRow(label: "Runners folder") {
                    Text(context.displayPath(runnerService.runnersDirectory.path))
                        .font(FocusType.settingsPath)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Show in Finder", action: showRunnersFolder)
                }
            }
            SettingsHelp(text: "Each runner keeps its work files and logs in its own folder here.")
        }
        .controlSize(.large)
        .confirmationDialog("Clear the local cache?", isPresented: Bindable(cache).isShowingClearConfirmation) {
            Button("Clear Cache", role: .destructive) { Task { await cache.confirmClear() } }
            Button("Cancel", role: .cancel, action: cache.cancelClear)
        } message: {
            Text("Every saved cache is deleted and saves in progress are dropped. Jobs miss until they save again.")
        }
        .confirmationDialog("Remove the network isolation helper?", isPresented: $isConfirmingHelperRemoval) {
            Button("Remove Helper", role: .destructive) { Task { await softnetHelper.remove() } }
        } message: {
            Text("Runners with Isolate network on can't start VMs until you set it up again.")
        }
        .task {
            openAtLogin.refresh()
            await notifications.refreshAuthorization()
            await softnetHelper.refresh()
            await cache.refresh()
        }
    }

    /// The local Actions cache VM runners use: space used, the size cap, and Clear Cache.
    @ViewBuilder
    private var cacheSection: some View {
        FocusFormSection(caption: "Cache") {
            FocusFormRow(label: "Space used") {
                Text(cache.usageText)
                    .font(FocusType.subheadline)
                    .foregroundStyle(.secondary)
                Button("Clear Cache…", action: cache.requestClear)
                    .disabled(cache.usage == nil)
            }
            FocusFormDivider()
            FocusFormRow(label: "Size cap") {
                Text("\(cache.capGB) GB")
                    .font(FocusType.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Stepper("Size cap", value: capBinding, in: AppSettings.minimumCacheSizeCapGB ... Self.maximumCacheSizeCapGB, step: Self.cacheCapStepGB)
                    .labelsHidden()
            }
        }
        if let message = cache.errorMessage {
            SettingsHelp(text: message)
        }
        SettingsHelp(text: "VM runners' caches stay on this Mac, in ~/.ghast/cache. Above the cap the least recently used are removed, and any unused for 7 days.")
    }

    private static let maximumCacheSizeCapGB = 10_000
    private static let cacheCapStepGB = 5

    /// Each step applies at once, so lowering the cap removes caches straight away.
    private var capBinding: Binding<Int> {
        Binding(get: { cache.capGB }, set: { value in Task { await cache.applyCap(value) } })
    }

    private var versionRow: some View {
        HStack(spacing: FocusMetrics.formRowInset) {
            VStack(alignment: .leading, spacing: FocusMetrics.settingsVersionLineGap) {
                Text("Ghast \(appVersion.display)").font(FocusType.body)
                Text(updates.statusLine(now: context.clock.now()))
                    .font(FocusType.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Check Now", action: updates.checkNow)
                .disabled(!updates.canCheckNow)
        }
        .padding(.horizontal, FocusMetrics.formRowInset)
        .frame(minHeight: FocusMetrics.settingsVersionRowHeight)
        .accessibilityElement(children: .combine)
    }

    /// A notify switch; switching one on is when Ghast first asks for permission.
    private func notifyBinding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { isOn in
                settings[keyPath: keyPath] = isOn
                guard isOn else { return }
                Task { await notifications.notifyToggleTurnedOn() }
            }
        )
    }

    private func showRunnersFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([runnerService.runnersDirectory])
    }
}

/// "1.1.0 (2)", from the app's Info.plist.
struct AppVersion: Equatable {
    let short: String
    let build: String

    var display: String { "\(short) (\(build))" }

    static var current: AppVersion {
        let info = Bundle.main.infoDictionary ?? [:]
        return AppVersion(
            short: info["CFBundleShortVersionString"] as? String ?? "?",
            build: info["CFBundleVersion"] as? String ?? "?"
        )
    }
}

extension EnvironmentValues {
    /// The version Settings › General shows; the running app's unless a snapshot pins one.
    @Entry var appVersion: AppVersion = .current
}
