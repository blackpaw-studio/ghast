import SwiftUI

/// What the design fixture opens the New Runner sheet on.
enum NewRunnerSheetPreset: Equatable, Sendable {
    case configure(customLabels: [String])
    /// A frozen "Setting Up" screen; nothing runs.
    case progress(SetupProgress)
}

/// The New Runner sheet: Configure, then Setting Up. Cancelling once the runner is registered
/// would unregister it on GitHub, so that asks first.
struct NewRunnerSheet: View {
    let services: RunnerFlowServices
    var preset: NewRunnerSheetPreset?
    /// Closes the sheet, selecting the given runner (Done, or a runner left behind).
    let finish: (_ selectRunnerID: String?) -> Void

    @State private var flow: RunnerSetupFlow?
    @State private var isConfirmingCancel = false
    @State private var localOnlyReason: String?
    @State private var cancelFailure: String?

    var body: some View {
        content
            .padding(FocusMetrics.sheetPadding)
            .frame(width: FocusMetrics.sheetWidth)
            .interactiveDismissDisabled(flow != nil)
            .alert(cancelTitle, isPresented: $isConfirmingCancel) {
                Button("Remove Runner", role: .destructive, action: performCancel)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(cancelMessage)
            }
            .alert(localOnlyTitle, isPresented: isShowing($localOnlyReason)) {
                Button("Remove from This Mac Only", role: .destructive, action: removeFromThisMacOnly)
                Button("Cancel", role: .cancel) { finish(flow?.runnerID) }
            }
            .alert("Couldn't Finish Cancelling", isPresented: isShowing($cancelFailure)) {
                Button("OK") { finish(flow?.runnerID) }
            } message: {
                Text(cancelFailure ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        if let flow {
            NewRunnerProgressView(
                progress: flow.progress,
                phase: flow.phase,
                cancel: requestCancel,
                done: { finish(flow.runnerID) },
                tryAgain: flow.tryAgain
            )
        } else if case let .progress(progress) = preset {
            NewRunnerProgressView(progress: progress, phase: .working, cancel: { finish(nil) }, done: {}, tryAgain: {})
        } else {
            NewRunnerConfigureView(initialCustomLabels: initialCustomLabels, create: start, cancel: { finish(nil) })
        }
    }

    private var initialCustomLabels: [String] {
        if case let .configure(labels) = preset { return labels }
        return []
    }

    private func start(_ request: NewRunnerRequest) {
        let flow = RunnerSetupFlow(request: request, services: services)
        self.flow = flow
        flow.start()
    }

    // MARK: Cancel

    private var runnerName: String { flow?.progress.runnerName ?? "" }
    private var scopeName: String { flow?.progress.scopeName ?? "" }

    private var cancelTitle: String { "Remove “\(runnerName)”?" }

    private var cancelMessage: String {
        let status = flow?.runnerID == nil ? "may already be registered" : "is already registered"
        return "\(runnerName) \(status) with \(scopeName). Cancelling stops it, removes it from \(scopeName) on GitHub, and moves its folder to the Trash."
    }

    private var localOnlyTitle: String {
        "Couldn't remove \(runnerName) from GitHub: \(localOnlyReason ?? "")"
    }

    private func requestCancel() {
        guard let flow else { return finish(nil) }
        if flow.requiresCancelConfirmation {
            isConfirmingCancel = true
        } else {
            performCancel()
        }
    }

    private func performCancel() {
        guard let flow else { return }
        Task {
            switch await flow.cancel() {
            case .cancelled: finish(nil)
            case let .needsLocalOnlyConfirmation(reason): localOnlyReason = reason
            case let .failed(message): cancelFailure = message
            }
        }
    }

    private func removeFromThisMacOnly() {
        guard let flow else { return }
        Task {
            do {
                try await flow.removeFromThisMacOnly()
                finish(nil)
            } catch {
                cancelFailure = error.localizedDescription
            }
        }
    }

    private func isShowing(_ value: Binding<String?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}
