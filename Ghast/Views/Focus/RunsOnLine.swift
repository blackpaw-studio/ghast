import AppKit
import SwiftUI

/// The workflow line that targets a VM runner (`runs-on: <name>`), with a Copy button. VM
/// runners take jobs by name only, so this replaces the Labels field for them.
struct RunsOnLine: View {
    let runnerName: String

    static func text(for name: String) -> String { "runs-on: \(name)" }

    private var line: String { Self.text(for: runnerName.isEmpty ? "<name>" : runnerName) }

    var body: some View {
        HStack(spacing: FocusMetrics.formCaptionGap) {
            Spacer(minLength: 0)
            Text(line)
                .font(FocusType.output)
                .tracking(FocusType.outputTracking)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line, forType: .string)
            }
            .buttonStyle(.link)
            .font(FocusType.subheadline)
            .disabled(runnerName.isEmpty)
            .accessibilityLabel("Copy \(line)")
        }
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
