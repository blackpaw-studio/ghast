import SwiftUI

/// The top of a runner's detail: status in words, its stats, its labels, and (for a stopped
/// or errored runner) what to do next.
struct RunnerStatusHeader<Actions: View>: View {
    let status: RunnerDisplayStatus
    let time: DisplayTime
    let secondaryLine: String
    let stats: [StatItem]
    let labels: [String]
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: FocusMetrics.headerStatsGap) {
                VStack(alignment: .leading, spacing: FocusMetrics.headerTitleSpacing) {
                    HStack(spacing: FocusMetrics.headerDotSpacing) {
                        StatusDot(status: status, size: FocusMetrics.statusDotHeader)
                        Text(status.title(time: time)).font(FocusType.title2)
                        if status.showsProgress {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Text(secondaryLine)
                        .font(FocusType.body)
                        .foregroundStyle(.secondary)
                        .padding(.leading, FocusMetrics.headerTextIndent)
                    if let fraction = status.downloadFraction {
                        ProgressView(value: fraction)
                            .frame(maxWidth: FocusMetrics.headerDownloadBarWidth)
                            .padding(.leading, FocusMetrics.headerTextIndent)
                            .padding(.top, FocusMetrics.headerDownloadBarTop)
                            .accessibilityLabel("Download progress")
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                StatRow(stats: stats)
                    .padding(.top, FocusMetrics.headerStatsTopOffset)
            }
            if !labels.isEmpty {
                LabelTokens(labels: labels)
                    .padding(.leading, FocusMetrics.headerTextIndent)
                    .padding(.top, FocusMetrics.headerTokensTop)
            }
            actions()
        }
        .padding(.top, FocusMetrics.headerTop)
        .padding(.bottom, FocusMetrics.headerBottom)
    }
}

/// The error or stopped runner's inline row: an optional hint, Start Runner and (error only)
/// Reconfigure….
struct HeaderActionRow: View {
    let hint: String?
    let start: () -> Void
    /// nil hides the Reconfigure… button.
    let reconfigure: (() -> Void)?
    var isReconfigureEnabled = false
    var isStartEnabled = true

    var body: some View {
        HStack(spacing: FocusMetrics.headerActionSpacing) {
            if let hint {
                Text(hint)
                    .font(FocusType.callout)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, FocusMetrics.headerHintGap - FocusMetrics.headerActionSpacing)
            }
            Button("Start Runner", action: start)
                .buttonStyle(.borderedProminent)
                .disabled(!isStartEnabled)
            if let reconfigure {
                Button("Reconfigure…", action: reconfigure)
                    .buttonStyle(.bordered)
                    .disabled(!isReconfigureEnabled)
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .padding(.leading, FocusMetrics.headerTextIndent)
        .padding(.top, FocusMetrics.headerActionsTop)
    }
}

/// Label-over-value stats separated by thin vertical rules.
struct StatRow: View {
    let stats: [StatItem]

    var body: some View {
        HStack(alignment: .top, spacing: FocusMetrics.statSpacing) {
            ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                if index > 0 {
                    FocusColor.separator
                        .frame(width: 1, height: FocusMetrics.statSeparatorHeight)
                        .padding(.top, FocusMetrics.statSeparatorTop)
                }
                VStack(alignment: .leading, spacing: FocusMetrics.statLabelSpacing) {
                    Text(stat.label).font(FocusType.subheadline).foregroundStyle(.secondary)
                    Text(stat.value).font(FocusType.body)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(stat.label), \(stat.spokenValue)")
            }
        }
    }
}
