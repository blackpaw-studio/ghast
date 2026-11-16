import SwiftUI

/// A runner's labels as quiet tokens that wrap onto more lines when the width runs out.
struct LabelTokens: View {
    let labels: [String]

    var body: some View {
        FlowLayout(spacing: FocusMetrics.tokenSpacing, lineSpacing: FocusMetrics.tokenSpacing) {
            ForEach(labels, id: \.self) { LabelToken(text: $0) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Labels: \(labels.joined(separator: ", "))")
    }
}

struct LabelToken: View {
    let text: String

    var body: some View {
        Text(text)
            .font(FocusType.token)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, FocusMetrics.tokenHorizontalPadding)
            .frame(height: FocusMetrics.tokenHeight)
            .background(
                RoundedRectangle(cornerRadius: FocusMetrics.tokenRadius, style: .continuous)
                    .fill(FocusColor.fill)
            )
    }
}

/// Lays children out left to right, starting a new line when the next one doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
