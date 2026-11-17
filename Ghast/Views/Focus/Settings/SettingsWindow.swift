import SwiftUI

/// The Settings window's two tabs.
enum SettingsTab: String, CaseIterable, Sendable {
    case general
    case account
}

private struct SettingsTabPresetKey: EnvironmentKey {
    static let defaultValue: SettingsTab? = nil
}

extension EnvironmentValues {
    /// The tab the design fixture opens Settings on; nil on a normal launch.
    var settingsTabPreset: SettingsTab? {
        get { self[SettingsTabPresetKey.self] }
        set { self[SettingsTabPresetKey.self] = newValue }
    }
}

/// Settings (⌘,): General and Account as native toolbar tabs.
struct SettingsWindow: View {
    @Environment(\.settingsTabPreset) private var preset
    @State private var selection: SettingsTab = .general
    @State private var didApplyPreset = false

    var body: some View {
        TabView(selection: $selection) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettingsView()
            }
            Tab("Account", systemImage: "person.crop.circle", value: SettingsTab.account) {
                AccountSettingsView()
            }
        }
        .frame(width: FocusMetrics.settingsWidth)
        // The kit shows only the tabs: no pane title and no bar under them.
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear {
            guard let preset, !didApplyPreset else { return }
            didApplyPreset = true
            selection = preset
        }
    }
}

/// A tab's content: the kit's padding, pinned to the top, at least the mockup's height.
struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: FocusMetrics.settingsSectionGap) {
            content()
        }
        .padding(.horizontal, FocusMetrics.settingsPadding.width)
        .padding(.vertical, FocusMetrics.settingsPadding.height)
        .frame(width: FocusMetrics.settingsWidth, alignment: .topLeading)
        .frame(minHeight: FocusMetrics.settingsContentMinHeight, alignment: .top)
        .environment(\.focusFormBoxRadius, FocusMetrics.settingsBoxRadius)
    }
}

/// A switch row in a settings group. The label stays the switch's VoiceOver name.
struct SettingsToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        FocusFormRow(label: label) {
            Toggle(label, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

/// Help text under a group, with an optional trailing button.
struct SettingsHelp: View {
    let text: String
    var buttonTitle: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: FocusMetrics.formRowInset) {
            Text(text)
                .font(FocusType.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let buttonTitle {
                Spacer(minLength: 0)
                Button(buttonTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, FocusMetrics.formRowInset)
        .padding(.top, FocusMetrics.settingsHelpTop - FocusMetrics.settingsSectionGap)
    }
}
