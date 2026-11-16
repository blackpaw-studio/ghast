import SwiftUI

/// New Runner, step two: "Setting Up {name}", one row per step.
struct NewRunnerProgressView: View {
    let progress: SetupProgress
    let phase: RunnerSetupFlow.Phase
    let cancel: () -> Void
    let done: () -> Void
    let tryAgain: () -> Void

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var isBusy: Bool {
        switch phase {
        case .cancelling, .cancelled, .needsLocalOnlyConfirmation: true
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Setting Up \(progress.runnerName)").font(FocusType.title2)
            VStack(spacing: 0) {
                ForEach(SetupStep.allCases, id: \.self) { step in
                    if step != .download { FocusFormDivider() }
                    SetupStepRow(title: progress.title(step), state: progress.state(step))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: FocusMetrics.formBoxRadius, style: .continuous)
                    .fill(FocusColor.group)
            )
            .padding(.top, FocusMetrics.sheetTitleToBox)
            HStack(spacing: FocusMetrics.sheetButtonSpacing) {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
                if isFailed {
                    Button("Try Again", action: tryAgain)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Done", action: done)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(phase != .finished)
                }
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .padding(.top, FocusMetrics.sheetFooterTop)
        }
    }
}

/// One step: status glyph, title (with the error under it on failure), trailing detail.
struct SetupStepRow: View {
    let title: String
    let state: SetupStepState

    var body: some View {
        HStack(spacing: FocusMetrics.setupStepIconGap) {
            icon.frame(width: FocusMetrics.setupStepIcon, height: FocusMetrics.setupStepIcon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(FocusType.body)
                if case let .failed(message) = state {
                    Text(message)
                        .font(FocusType.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: FocusMetrics.formRowInset)
            if let detail {
                Text(detail)
                    .font(FocusType.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, FocusMetrics.formRowInset)
        .frame(minHeight: FocusMetrics.setupStepRowHeight)
        .accessibilityElement(children: .combine)
    }

    private var detail: String? {
        switch state {
        case let .active(detail), let .done(detail): detail
        case .pending, .failed: nil
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white, .green)
                .accessibilityLabel("Done")
        case .active:
            ProgressView().controlSize(.small).accessibilityLabel("In progress")
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(FocusColor.tertiary)
                .accessibilityLabel("Not started")
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.white, .red)
                .accessibilityLabel("Failed")
        }
    }
}
