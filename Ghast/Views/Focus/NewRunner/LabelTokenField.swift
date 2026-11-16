import SwiftUI

/// New Runner's labels: the fixed defaults, removable custom labels, and a field that commits
/// on Return or comma. Rejected text (a duplicate, or whitespace) stays in the field to fix.
struct LabelTokenField: View {
    @Binding var labels: LabelTokenList
    @State private var text = ""

    var body: some View {
        FlowLayout(spacing: FocusMetrics.tokenSpacing, lineSpacing: FocusMetrics.tokenSpacing) {
            ForEach(labels.defaults, id: \.self) { LabelToken(text: $0) }
            ForEach(labels.custom, id: \.self) { label in
                RemovableLabelToken(text: label) { labels = labels.removing(label) }
            }
            TextField("Add Label", text: $text)
                .textFieldStyle(.plain)
                .font(FocusType.body)
                .frame(width: FocusMetrics.labelFieldTextWidth)
                .onSubmit(commit)
                .onChange(of: text) { _, new in apply(labels.typing(new)) }
                .accessibilityLabel("Add Label")
        }
        .padding(FocusMetrics.labelFieldInset)
        .frame(maxWidth: .infinity, minHeight: FocusMetrics.labelFieldHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: FocusMetrics.labelFieldRadius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .strokeBorder(FocusColor.separator, lineWidth: 0.5)
        )
    }

    private func commit() { apply(labels.committing(text)) }

    private func apply(_ edit: LabelTokenList.Edit) {
        if edit.tokens != labels { labels = edit.tokens }
        if edit.remainder != text { text = edit.remainder }
    }
}

/// A custom label with a small × to remove it.
private struct RemovableLabelToken: View {
    let text: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: FocusMetrics.labelRemoveGap) {
            Text(text)
                .font(FocusType.token)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: FocusMetrics.labelRemoveGlyph, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove \(text)")
            .accessibilityLabel("Remove label \(text)")
        }
        .padding(.horizontal, FocusMetrics.tokenHorizontalPadding)
        .frame(height: FocusMetrics.tokenHeight)
        .background(
            RoundedRectangle(cornerRadius: FocusMetrics.tokenRadius, style: .continuous)
                .fill(FocusColor.fill)
        )
    }
}
