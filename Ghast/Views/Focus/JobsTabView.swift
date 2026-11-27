import SwiftUI

/// A VM runner's Jobs tab: what its VMs ran, newest first. A row with a run opens it on GitHub.
struct JobsTabView: View {
    let records: [JobHistoryRecord]
    let copy: (String) -> Void
    @Environment(\.focusContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var selectedID: JobHistoryRecord.ID?
    @FocusState private var isFocused: Bool

    private static let emptyText = "No jobs yet. Jobs this runner runs appear here."
    private static let rowSpacing: CGFloat = 2

    var body: some View {
        // A running row's length counts up each second; otherwise only "3 min ago" ages.
        let period: TimeInterval = records.contains { $0.result == .running } ? 1 : 30
        TimelineView(.periodic(from: .now, by: period)) { _ in
            let now = context.clock.now()
            Group {
                if records.isEmpty {
                    Text(Self.emptyText)
                        .font(FocusType.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, FocusMetrics.contentInset)
                        .padding(.top, FocusMetrics.formHelpTop)
                } else {
                    list(now: now)
                }
            }
        }
        .focusContentLayer()
    }

    private func list(now: Date) -> some View {
        ScrollView {
            VStack(spacing: Self.rowSpacing) {
                ForEach(records) { record in
                    JobHistoryRow(record: record, now: now, isSelected: selectedID == record.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedID = record.id
                            open(record)
                        }
                        .contextMenu {
                            if let url = record.runURL {
                                Button("Open Run on GitHub") { openURL(url) }
                                Button("Copy Run URL") { copy(url.absoluteString) }
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(record.runURL == nil ? [] : .isButton)
                        .accessibilityAction(named: "Open Run on GitHub") { open(record) }
                }
            }
            .padding(.horizontal, FocusMetrics.contentInset - JobHistoryRow.inset)
            .padding(.vertical, FocusMetrics.formHelpTop)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.return) {
            guard let selected, selected.runURL != nil else { return .ignored }
            open(selected)
            return .handled
        }
        .onKeyPress(.downArrow) { move(by: 1) }
        .onKeyPress(.upArrow) { move(by: -1) }
    }

    private var selected: JobHistoryRecord? { records.first { $0.id == selectedID } }

    private func open(_ record: JobHistoryRecord) {
        guard let url = record.runURL else { return }
        openURL(url)
    }

    private func move(by offset: Int) -> KeyPress.Result {
        guard !records.isEmpty else { return .ignored }
        let current = records.firstIndex { $0.id == selectedID }
        let next = current.map { min(max($0 + offset, 0), records.count - 1) } ?? 0
        selectedID = records[next].id
        return .handled
    }
}

/// One job: its result, its name and where it ran, and when it started and how long it took.
struct JobHistoryRow: View {
    let record: JobHistoryRecord
    let now: Date
    let isSelected: Bool

    static let inset: CGFloat = 10
    private static let resultColumnWidth: CGFloat = 116
    private static let timeColumnWidth: CGFloat = 140
    private static let rowCorner: CGFloat = 8
    private static let verticalPadding: CGFloat = 8
    private static let symbolSize: CGFloat = 14
    /// Wide enough for the widest symbol, so the result words line up.
    private static let symbolColumn: CGFloat = 18
    private static let columnSpacing: CGFloat = 12
    private static let lineSpacing: CGFloat = 2

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.columnSpacing) {
            Label {
                Text(record.result.title)
                    .font(FocusType.callout)
            } icon: {
                Image(systemName: Self.symbol(for: record.result))
                    .font(.system(size: Self.symbolSize))
                    .foregroundStyle(Self.color(for: record.result))
                    .frame(width: Self.symbolColumn)
            }
            .frame(width: Self.resultColumnWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: Self.lineSpacing) {
                Text(record.displayName)
                    .font(FocusType.body)
                    .lineLimit(1)
                if let detail = record.detailLine {
                    Text(detail)
                        .font(FocusType.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: Self.lineSpacing) {
                Text(Self.relative(record.startedAt, now: now))
                    .font(FocusType.callout)
                    .help(record.startedAt.formatted(date: .abbreviated, time: .standard))
                Text(DurationFormat.job(record.duration(now: now)))
                    .font(FocusType.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: Self.timeColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, Self.verticalPadding)
        .background(isSelected ? FocusColor.fill : .clear, in: RoundedRectangle(cornerRadius: Self.rowCorner))
    }

    /// The existing status colours: green done, orange running, red wrong, grey unsure.
    static func color(for result: JobHistoryResult) -> Color {
        switch result {
        case .succeeded: .green
        case .running: .orange
        case .failed, .didNotStart: .red
        case .cancelled, .unknown: Color(nsColor: .secondaryLabelColor)
        }
    }

    static func symbol(for result: JobHistoryResult) -> String {
        switch result {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "slash.circle"
        case .running: "play.circle.fill"
        case .didNotStart: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
