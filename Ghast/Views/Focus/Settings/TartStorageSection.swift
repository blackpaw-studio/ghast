import SwiftUI

/// Settings › General › Tart Storage: what Tart keeps on disk, with Remove per image and
/// Remove Unused. The section refreshes when it appears and when a pull finishes.
struct TartStorageSection: View {
    @Environment(TartStorageModel.self) private var model

    var body: some View {
        @Bindable var model = model
        content
            .task { await model.refresh() }
            .onChange(of: model.pullingImages) { _, pulling in
                Task { await model.pullsChanged(to: pulling) }
            }
            .confirmationDialog(
                model.removal.map { "Remove \($0.displayName)?" } ?? "Remove this image?",
                isPresented: $model.isShowingRemoveConfirmation,
                presenting: model.removal
            ) { _ in
                Button("Remove", role: .destructive) { Task { await model.confirmRemove() } }
                Button("Cancel", role: .cancel, action: model.cancelRemove)
            } message: { image in
                Text(model.removalMessage(for: image))
            }
            .confirmationDialog(
                model.removeUnusedTitle,
                isPresented: $model.isShowingRemoveUnusedConfirmation
            ) {
                Button("Remove Unused", role: .destructive) { Task { await model.confirmRemoveUnused() } }
                Button("Cancel", role: .cancel, action: model.cancelRemove)
            } message: {
                Text(model.removeUnusedMessage)
            }
    }

    @ViewBuilder
    private var content: some View {
        FocusFormSection(caption: "Tart Storage") {
            FocusFormRow(label: model.headerText) {
                Button("Remove Unused…", action: model.requestRemoveUnused)
                    .disabled(!model.canRemoveUnused)
            }
            if model.hasLoaded, model.inventory.pulled.isEmpty, model.inventory.localVMs.isEmpty {
                FocusFormDivider()
                FocusFormRow(label: "No images or VMs") { EmptyView() }
                    .foregroundStyle(.secondary)
            }
            ForEach(model.inventory.pulled) { image in
                FocusFormDivider()
                StoredImageRow(image: image)
            }
            if !model.inventory.localVMs.isEmpty {
                FocusFormDivider()
                Text("Local VMs")
                    .font(FocusType.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, FocusMetrics.formRowInset)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
                ForEach(model.inventory.localVMs) { image in
                    StoredImageRow(image: image)
                    if image.id != model.inventory.localVMs.last?.id { FocusFormDivider() }
                }
            }
        }
        if let message = model.errorMessage {
            SettingsHelp(text: message)
        }
        SettingsHelp(text: "VM runners pull their image the first time they need it. Ghast never removes one on its own: free space here when the disk runs low.")
    }
}

/// One image or VM: its name, who uses it and when it was last used, its size, and Remove.
private struct StoredImageRow: View {
    @Environment(TartStorageModel.self) private var model
    let image: StoredImage

    private static let verticalPadding: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: FocusMetrics.formRowInset) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(image.displayName).font(FocusType.body)
                    Text("\(image.usageText) · \(model.lastUsedText(image))")
                        .font(FocusType.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(model.sizeText(image))
                    .font(FocusType.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Remove…") { model.requestRemove(image) }
                    .disabled(image.removeBlockReason != nil)
                    .help(image.removeBlockReason ?? "")
            }
            if let error = model.rowErrors[image.id] {
                Text(error)
                    .font(FocusType.subheadline)
                    .foregroundStyle(FocusColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, FocusMetrics.formRowInset)
        .padding(.vertical, Self.verticalPadding)
        .accessibilityElement(children: .contain)
    }
}
