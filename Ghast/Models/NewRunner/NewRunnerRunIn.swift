import Foundation

/// New Runner's "Run in" choice.
enum NewRunnerRunIn: Hashable, Sendable {
    case thisMac
    case tartVM

    var title: String {
        switch self {
        case .thisMac: "This Mac"
        case .tartVM: "Tart VM"
        }
    }
}
