import SwiftUI

/// The image choice for a Tart VM runner: a macOS version, an Xcode release (or none), or a
/// custom reference. It edits `image` directly, so the saved value is always the exact ref.
///
/// With `autoPicksNewest` (the New Runner sheet), an empty `image` becomes the newest Xcode
/// release once the versions arrive. Elsewhere the picker never changes the image unless the
/// user chooses.
struct TartImagePicker<RowView: View>: View {
    @Binding var image: String
    let versions: any TartXcodeVersionProviding
    /// False where another field already edits the custom ref (the Configuration tab).
    var showsCustomField = true
    /// True only where the image starts empty and should default to the newest Xcode.
    var autoPicksNewest = false
    /// Lays out one labelled row, so the New Runner sheet and the Configuration tab each keep
    /// their own row style.
    @ViewBuilder let row: (_ label: String, _ value: AnyView) -> RowView

    @Environment(\.onTartVersionsLoaded) private var onVersionsLoaded

    @State private var isCustom: Bool
    @State private var macOS: TartMacOS
    @State private var wantsXcode: Bool
    @State private var loaded: [TartMacOS: TartXcodeVersions] = [:]

    private static var customTag: String { "custom" }

    init(
        image: Binding<String>,
        versions: any TartXcodeVersionProviding,
        showsCustomField: Bool = true,
        autoPicksNewest: Bool = false,
        @ViewBuilder row: @escaping (_ label: String, _ value: AnyView) -> RowView
    ) {
        _image = image
        self.versions = versions
        self.showsCustomField = showsCustomField
        self.autoPicksNewest = autoPicksNewest
        self.row = row
        let parsed = TartImageCatalog.parse(image.wrappedValue)
        _isCustom = State(initialValue: parsed == nil && !image.wrappedValue.isEmpty)
        _macOS = State(initialValue: parsed?.macOS ?? .tahoe)
        _wantsXcode = State(initialValue: parsed?.xcodeTag != nil || image.wrappedValue.isEmpty)
    }

    private var parsed: TartImageCatalog.Parsed? { TartImageCatalog.parse(image) }
    private var isResolving: Bool { autoPicksNewest && image.isEmpty && !isCustom }
    private var current: TartXcodeVersions? { loaded[macOS] }

    var body: some View {
        Group {
            row("macOS", AnyView(osPicker))
            if isCustom {
                if showsCustomField {
                    FocusFormDivider()
                    row("Custom image", AnyView(customField))
                }
            } else {
                FocusFormDivider()
                row("Xcode", AnyView(xcodePicker))
                if current?.source == .fallback {
                    Text("Couldn't load Xcode versions; showing a short list.")
                        .font(FocusType.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, FocusMetrics.formRowInset)
                        .padding(.bottom, 6)
                }
            }
        }
        .task(id: macOS) { await load(macOS) }
        .onChange(of: image) { syncFromImage() }
    }

    // MARK: Controls

    private var osBinding: Binding<String> {
        Binding(
            get: { isCustom ? Self.customTag : macOS.rawValue },
            set: { choose(osNamed: $0) }
        )
    }

    private var osPicker: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Picker("macOS", selection: osBinding) {
                ForEach(TartMacOS.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                Divider()
                Text("Custom image…").tag(Self.customTag)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var xcodeBinding: Binding<String?> {
        Binding(
            get: { parsed?.xcodeTag },
            set: { setXcode($0) }
        )
    }

    @ViewBuilder
    private var xcodePicker: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if isResolving {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                Picker("Xcode", selection: xcodeBinding) {
                    Text("None (base image)").tag(String?.none)
                    Divider()
                    ForEach(xcodeTags, id: \.self) { Text($0 == "latest" ? "Latest" : $0).tag(String?.some($0)) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    /// The loaded releases, plus the one in use when it isn't among them (an older pin, or `latest`).
    private var xcodeTags: [String] {
        let tags = current?.tags ?? []
        guard let tag = parsed?.xcodeTag, !tags.contains(tag) else { return tags }
        return [tag] + tags
    }

    private var customField: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Custom image", text: $image, prompt: Text("OCI reference or local VM name"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            Text(TartImageCatalog.customImageHint)
                .font(FocusType.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    // MARK: Choices

    private func choose(osNamed name: String) {
        guard let next = TartMacOS(rawValue: name) else {
            isCustom = true
            return
        }
        isCustom = false
        macOS = next
        if wantsXcode {
            image = loaded[next]?.tags.first.map { TartImageCatalog.ref(macOS: next, xcode: $0) } ?? ""
        } else {
            image = TartImageCatalog.ref(macOS: next, xcode: nil)
        }
    }

    private func setXcode(_ tag: String?) {
        wantsXcode = tag != nil
        image = TartImageCatalog.ref(macOS: macOS, xcode: tag)
    }

    /// An edit outside the picker (the Configuration tab's ref field) moves the menus with it.
    private func syncFromImage() {
        if let parsed {
            // Typing a custom ref that happens to be curated doesn't leave custom mode.
            guard !isCustom || !showsCustomField else { return }
            isCustom = false
            macOS = parsed.macOS
            wantsXcode = parsed.xcodeTag != nil
        } else if !image.isEmpty {
            isCustom = true
        }
    }

    /// The image to default to once versions load, or nil to leave the current one alone.
    static func newestImage(
        current: String, isCustom: Bool, wantsXcode: Bool, autoPicks: Bool,
        macOS: TartMacOS, versions: TartXcodeVersions
    ) -> String? {
        guard autoPicks, current.isEmpty, !isCustom, wantsXcode, let newest = versions.tags.first else { return nil }
        return TartImageCatalog.ref(macOS: macOS, xcode: newest)
    }

    private func load(_ target: TartMacOS) async {
        let result: TartXcodeVersions
        if let cached = loaded[target] { result = cached } else { result = await versions.versions(for: target) }
        guard !Task.isCancelled else { return }
        loaded[target] = result
        if target == macOS,
           let pick = Self.newestImage(current: image, isCustom: isCustom, wantsXcode: wantsXcode, autoPicks: autoPicksNewest, macOS: target, versions: result) {
            image = pick
        }
        onVersionsLoaded?(target)
    }
}

extension EnvironmentValues {
    /// Called once a macOS version's Xcode releases have loaded into the image picker, so a
    /// snapshot can wait for that instead of guessing.
    @Entry var onTartVersionsLoaded: (@MainActor (TartMacOS) -> Void)? = nil
}
