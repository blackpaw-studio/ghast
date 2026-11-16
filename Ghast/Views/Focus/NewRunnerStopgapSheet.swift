import SwiftUI
import os

/// The previous New Runner flow, shown from the Focus window until its redesign lands.
struct NewRunnerStopgapSheet: View {
    @Environment(\.gitHubAPIService) private var api
    @State private var repositories: [GitHubRepository] = []
    private static let logger = Logger(subsystem: "net.evancoleman.ghast", category: "new-runner")

    var body: some View {
        NewRunnerFlowView(repositories: repositories)
            .frame(minWidth: 800, minHeight: 600)
            .task {
                do {
                    repositories = try await api.fetchRepositories()
                } catch {
                    Self.logger.error("Couldn't load repositories: \(error.localizedDescription, privacy: .public)")
                }
            }
    }
}
