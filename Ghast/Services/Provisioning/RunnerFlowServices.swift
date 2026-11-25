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
    /// Builds a VM runner's demand source, so Remove can delete its scale set. Nil where VM
    /// runners never reach GitHub (the design fixture).
    var demandSources: (any JobDemandSourceMaking)? = nil
    /// Finds Tart for the New Runner sheet's Run in choice.
    var tartLocator = TartLocator()
    /// Lists the Xcode images for the New Runner sheet's and Configuration tab's image picker.
    var xcodeVersions: any TartXcodeVersionProviding = GHCRXcodeVersionProvider()
    /// What this Mac has to give its VMs, for the Configuration tab's oversubscription warning.
    var hostCapacity: any HostCapacity = SystemHostCapacity()
    /// The image's own CPU, memory and disk, for the Configuration tab's placeholders.
    var imageDefaults: any TartImageDefaultsProviding = NoImageDefaults()

    var remover: RunnerRemover {
        RunnerRemover(api: api, runnerService: runnerService, registrar: registrar, trasher: trasher, demandSources: demandSources)
    }
}

extension EnvironmentValues {
    /// Set on the main window; nil in previews and tests that don't run a flow.
    @Entry var runnerFlowServices: RunnerFlowServices?
}
