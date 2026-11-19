import AppKit
import SwiftUI

/// A monospaced command with a Copy button, right-aligned in its row.
struct CopyableCommand: View {
    let text: String
    var isEnabled = true

    var body: some View {
        HStack(spacing: FocusMetrics.formCaptionGap) {
            Spacer(minLength: 0)
            Text(text)
                .font(FocusType.output)
                .tracking(FocusType.outputTracking)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .buttonStyle(.link)
            .font(FocusType.subheadline)
            .disabled(!isEnabled)
            .accessibilityLabel("Copy \(text)")
        }
    }
}

/// The workflow line that targets a VM runner (`runs-on: <name>`), with a Copy button. VM
/// runners take jobs by name only, so this replaces the Labels field for them.
struct RunsOnLine: View {
    let runnerName: String

    static func text(for name: String) -> String { "runs-on: \(name)" }

    var body: some View {
        CopyableCommand(text: Self.text(for: runnerName.isEmpty ? "<name>" : runnerName), isEnabled: !runnerName.isEmpty)
    }
}

/// One copyable `tart exec` line per VM a shell can reach. Ghast opens no terminal itself.
struct VMShellCommands: View {
    let clones: [String]

    static func command(for clone: String) -> String { "tart exec -it \(clone) zsh" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(clones, id: \.self) { clone in
                HStack(alignment: .firstTextBaseline, spacing: FocusMetrics.formCaptionGap) {
                    Text("Shell").font(FocusType.subheadline).foregroundStyle(.secondary)
                    CopyableCommand(text: Self.command(for: clone))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shell into a running VM")
    }
}

/// Shown once on a VM runner saved before on-demand VMs: its labels no longer pick it.
struct OnDemandNote: View {
    let runnerName: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: FocusMetrics.formCaptionGap) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            (Text("Labels no longer apply. Use ") + Text(RunsOnLine.text(for: runnerName)).font(FocusType.output) + Text("."))
                .font(FocusType.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button("Dismiss", action: dismiss)
                .buttonStyle(.link)
                .font(FocusType.subheadline)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
