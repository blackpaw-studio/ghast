import SwiftUI

extension View {
    /// The confirmations and errors of Remove Runner, Reconfigure and Remove from GitHub.
    func runnerFlowAlerts(_ flows: RunnerFlowCoordinator?) -> some View {
        modifier(RunnerFlowAlerts(flows: flows))
    }
}

private struct RunnerFlowAlerts: ViewModifier {
    let flows: RunnerFlowCoordinator?

    private var prompt: RunnerFlowPrompt? { flows?.prompt }

    func body(content: Content) -> some View {
        content.alert(
            prompt.map(Self.title) ?? "",
            isPresented: Binding(get: { prompt != nil }, set: { if !$0 { flows?.dismiss() } }),
            presenting: prompt
        ) { prompt in
            buttons(for: prompt)
        } message: { prompt in
            Self.message(for: prompt).map(Text.init)
        }
    }

    @ViewBuilder
    private func buttons(for prompt: RunnerFlowPrompt) -> some View {
        switch prompt {
        case .confirmRemove:
            Button("Remove Runner", role: .destructive) { confirm(prompt) }
            Button("Cancel", role: .cancel) {}
        case .confirmRemoveLocalOnly:
            Button("Remove from This Mac Only", role: .destructive) { confirm(prompt) }
            Button("Cancel", role: .cancel) {}
        case .confirmReconfigure:
            Button("Reconfigure") { confirm(prompt) }
            Button("Cancel", role: .cancel) {}
        case .confirmRemoveFromGitHub:
            Button("Remove from GitHub", role: .destructive) { confirm(prompt) }
            Button("Cancel", role: .cancel) {}
        case .failure:
            Button("OK", role: .cancel) {}
        }
    }

    private func confirm(_ prompt: RunnerFlowPrompt) {
        guard let flows else { return }
        Task { await flows.confirm(prompt) }
    }

    static func title(for prompt: RunnerFlowPrompt) -> String {
        switch prompt {
        case let .confirmRemove(runner, _): "Remove “\(runner.name)”?"
        case let .confirmRemoveLocalOnly(runner, reason): "Couldn't remove \(runner.name) from GitHub: \(reason)"
        case let .confirmReconfigure(runner): "Reconfigure “\(runner.name)”?"
        case let .confirmRemoveFromGitHub(name, _, _): "Remove “\(name)” from GitHub?"
        case let .failure(title, _): title
        }
    }

    static func message(for prompt: RunnerFlowPrompt) -> String? {
        switch prompt {
        case let .confirmRemove(runner, _):
            "Ghast stops the runner, removes it from \(runner.scope.displayName) on GitHub, and moves its folder to the Trash."
        case .confirmRemoveLocalOnly:
            "Ghast can still stop it and move its folder to the Trash. It stays registered on GitHub until it's removed there."
        case let .confirmReconfigure(runner):
            "Ghast registers \(runner.name) with \(runner.scope.displayName) again using a new token."
        case let .confirmRemoveFromGitHub(name, scope, _):
            "\(scope.displayName) stops sending jobs to \(name). Its machine can't connect again until the runner is set up again."
        case let .failure(_, message):
            message
        }
    }
}
