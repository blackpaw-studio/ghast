import Foundation
import SwiftUI

/// The services the New Runner, Remove and Reconfigure flows use. Built once at the
/// composition root; tests and the design fixture swap in fakes.
@MainActor
struct RunnerFlowServices {
    let api: any GitHubAPIServiceProtocol
    let runnerService: RunnerService
    let downloader: any RunnerDownloader
    let registrar: RunnerRegistrar
    let trasher: any FileTrasher
    /// Times the connect timeout.
    let sleeper: Sleeper
    /// A runner's process state and parsed output. Read inside observation tracking, so it
    /// must read observable state.
    let readRunner: @MainActor (String) -> (RunnerProcessState?, RunnerActivity)
    /// Finds Tart for the New Runner sheet's Run in choice.
    var tartLocator = TartLocator()

    var remover: RunnerRemover {
        RunnerRemover(api: api, runnerService: runnerService, registrar: registrar, trasher: trasher)
    }
}

extension EnvironmentValues {
    /// Set on the main window; nil in previews and tests that don't run a flow.
    @Entry var runnerFlowServices: RunnerFlowServices?
}
