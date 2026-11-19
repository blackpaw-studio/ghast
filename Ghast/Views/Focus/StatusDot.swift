import SwiftUI

/// A runner's status dot. Colour always comes with words elsewhere, so VoiceOver skips it.
struct StatusDot: View {
    let status: RunnerDisplayStatus
    var size: CGFloat = FocusMetrics.statusDot

    private static let ringWidth: CGFloat = 1.5

    var body: some View {
        Group {
            switch status {
            case .idle, .onDemand(.waitingForJobs):
                Circle().fill(Color.green)
            case .runningJob, .remoteBusy, .onDemand(.running):
                Circle()
                    .fill(Color.orange)
                    .background(
                        Circle()
                            .fill(Color.orange.opacity(FocusMetrics.runningHaloOpacity))
                            .padding(-FocusMetrics.runningHaloWidth)
                    )
            case .error:
                Circle().fill(Color.red)
            case .onDemand(.standingBy), .onDemand(.handingOff):
                Circle().strokeBorder(Color(nsColor: .secondaryLabelColor), style: StrokeStyle(lineWidth: Self.ringWidth, dash: [2, 1.5]))
            case .stopped, .starting, .pulling, .booting, .cleaningUp, .stopping, .offline, .onDemand:
                Circle().strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: Self.ringWidth)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
