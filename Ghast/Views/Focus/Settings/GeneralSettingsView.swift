import AppKit
import SwiftUI

/// Settings › General: startup, menu bar and notifications, updates, and the runners folder.
struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(OpenAtLoginModel.self) private var openAtLogin
    @Environment(NotificationService.self) private var notifications
    @Environment(UpdateStatusModel.self) private var updates
    @Environment(RunnerService.self) private var runnerService
    @Environment(\.focusContext) private var context
    @Environment(\.openURL) private var openURL

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
        .task {
            openAtLogin.refresh()
            await notifications.refreshAuthorization()
        }
    }

    private var versionRow: some View {
        HStack(spacing: FocusMetrics.formRowInset) {
            VStack(alignment: .leading, spacing: FocusMetrics.settingsVersionLineGap) {
                Text("Ghast \(AppVersion.current.display)").font(FocusType.body)
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
