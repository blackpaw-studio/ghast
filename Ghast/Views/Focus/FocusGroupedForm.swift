import SwiftUI

/// A System Settings style group: caption above, rounded box of rows, help below.
struct FocusFormSection<Content: View>: View {
    let caption: String
    @ViewBuilder let content: () -> Content
    @Environment(\.focusFormBoxRadius) private var boxRadius

    var body: some View {
        VStack(alignment: .leading, spacing: FocusMetrics.formCaptionGap) {
            Text(caption)
                .font(FocusType.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, FocusMetrics.formRowInset)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: boxRadius, style: .continuous)
                    .fill(FocusColor.group)
            )
        }
    }
}

/// A label on the left and its value or control on the right.
struct FocusFormRow<Value: View>: View {
    let label: String
    var height: CGFloat = FocusMetrics.formRowHeight
    @ViewBuilder let value: () -> Value

    var body: some View {
        HStack(spacing: FocusMetrics.formRowInset) {
            Text(label).font(FocusType.body)
            Spacer(minLength: 0)
            value()
        }
        .padding(.horizontal, FocusMetrics.formRowInset)
        .frame(minHeight: height)
    }
}

/// The 1 pt rule between rows, inset from the leading edge.
struct FocusFormDivider: View {
    var body: some View {
        FocusColor.separator
            .frame(height: 1)
            .padding(.leading, FocusMetrics.formRowInset)
    }
}

private struct FocusFormBoxRadiusKey: EnvironmentKey {
    static let defaultValue = FocusMetrics.formBoxRadius
}

extension EnvironmentValues {
    /// Group corner radius: Configuration.png measures 10, Settings.png the kit's 12.
    var focusFormBoxRadius: CGFloat {
        get { self[FocusFormBoxRadiusKey.self] }
        set { self[FocusFormBoxRadiusKey.self] = newValue }
    }
}
