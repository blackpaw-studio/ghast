import SwiftUI

/// The runner's live output: header buttons, find bar, and one row per line.
struct RunnerOutputView: View {
    let lines: [OutputLine]
    /// The last line is the running job's: it gets the live treatment.
    let hasLiveLine: Bool
    @Bindable var pane: OutputPaneState
    let copyAll: () -> Void
    let clear: () -> Void

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAtEnd = true
    @FocusState private var isFindFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.top, FocusMetrics.outputHeaderTop)
                .padding(.horizontal, FocusMetrics.contentInset)
            if pane.isFindVisible {
                findBar
                    .padding(.top, FocusMetrics.headerActionSpacing)
                    .padding(.horizontal, FocusMetrics.contentInset)
            }
            if lines.isEmpty {
                Text("No output yet. Start the runner to see its output.")
                    .font(FocusType.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                lineList
            }
        }
        .onChange(of: lines) { _, new in
            pane.find.update(query: pane.query, lines: new)
            if pane.follow.isFollowing { position.scrollTo(edge: .bottom) }
        }
        .onChange(of: pane.follow.jumpRequest) { position.scrollTo(edge: .bottom) }
        .onChange(of: pane.find.current) { _, match in
            guard let match else { return }
            withAnimation { position.scrollTo(id: match.lineID, anchor: .center) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: FocusMetrics.outputButtonSpacing) {
            Text("Output").font(FocusType.headline)
            Spacer(minLength: 0)
            iconButton("arrow.down.to.line", label: "Follow Output", isOn: pane.follow.isFollowing) { pane.follow.follow() }
            iconButton("magnifyingglass", label: "Find") { pane.showFind() }
            iconButton("square.on.square", label: "Copy All Output", action: copyAll)
                .disabled(lines.isEmpty)
            iconButton("trash", label: "Clear Output", action: clear)
                .disabled(lines.isEmpty)
        }
    }

    private func iconButton(_ symbol: String, label: String, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: FocusMetrics.outputButtonGlyph))
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(nsColor: .secondaryLabelColor)))
                .frame(width: FocusMetrics.outputButtonSize, height: FocusMetrics.outputButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: Find

    private var findBar: some View {
        HStack(spacing: FocusMetrics.headerActionSpacing) {
            TextField("Find", text: $pane.query)
                .textFieldStyle(.roundedBorder)
                .focused($isFindFieldFocused)
                .onSubmit { pane.find.next() }
                .onChange(of: pane.query) { _, query in pane.find.update(query: query, lines: lines) }
                .onExitCommand { pane.hideFind(lines: lines) }
                .frame(maxWidth: FocusMetrics.findFieldWidth)
            Text(pane.find.matchCountText)
                .font(FocusType.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            ControlGroup {
                Button { pane.find.previous() } label: { Image(systemName: "chevron.left") }
                    .help("Find Previous")
                    .accessibilityLabel("Find Previous")
                Button { pane.find.next() } label: { Image(systemName: "chevron.right") }
                    .help("Find Next")
                    .accessibilityLabel("Find Next")
            }
            .fixedSize()
            .disabled(pane.find.current == nil)
            Spacer(minLength: 0)
            Button("Done") { pane.hideFind(lines: lines) }
        }
        .controlSize(.small)
        .onAppear { isFindFieldFocused = true }
        .onChange(of: pane.findFocusRequest) { isFindFieldFocused = true }
    }

    // MARK: Lines

    private var lineList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    let isLive = hasLiveLine && line.id == lines.last?.id
                    OutputLineRow(
                        line: line,
                        isLive: isLive,
                        matches: pane.find.matches.filter { $0.lineID == line.id }.map(\.range),
                        currentMatch: pane.find.current?.lineID == line.id ? pane.find.current?.range : nil
                    )
                    .id(line.id)
                }
            }
            .scrollTargetLayout()
            .padding(.top, FocusMetrics.outputLinesTop)
            .padding(.bottom, FocusMetrics.contentInset)
            .padding(.horizontal, FocusMetrics.contentInset)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - FocusMetrics.outputLineHeight
        } action: { _, atEnd in
            isAtEnd = atEnd
        }
        .onScrollPhaseChange { _, phase in
            // Only the user's own scrolling turns Follow off; output arriving never does.
            if phase == .interacting || phase == .decelerating { pane.follow.userScrolled(isAtEnd: isAtEnd) }
        }
    }
}

/// One line: time, a glyph for what happened, and the text.
struct OutputLineRow: View {
    let line: OutputLine
    let isLive: Bool
    let matches: [Range<Int>]
    let currentMatch: Range<Int>?
    @Environment(\.focusContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            Text(line.clockText)
                .foregroundStyle(.secondary)
                .frame(width: FocusMetrics.outputTimeColumn, alignment: .leading)
            glyph
                .frame(width: FocusMetrics.outputGlyphColumn)
                .padding(.trailing, FocusMetrics.outputGlyphTextGap)
            Text(highlighted)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            if isLive {
                Cursor(blinks: context.animatesCursor && !reduceMotion)
                    .padding(.leading, FocusMetrics.cursorGap)
            }
            Spacer(minLength: 0)
        }
        .font(FocusType.output)
        .tracking(FocusType.outputTracking)
        .lineLimit(1)
        .frame(height: isLive ? FocusMetrics.liveLineHeight : FocusMetrics.outputLineHeight)
        .background {
            if isLive {
                RoundedRectangle(cornerRadius: FocusMetrics.liveLineRadius, style: .continuous)
                    .fill(FocusColor.fill)
                    .padding(.horizontal, -FocusMetrics.liveLineInset)
            }
        }
        .padding(.top, isLive ? FocusMetrics.liveLineTopGap : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var glyph: some View {
        switch line.kind {
        case .connected:
            Image(systemName: "checkmark").font(.system(size: FocusMetrics.outputGlyphSize, weight: .bold)).foregroundStyle(.green)
        case .jobStarted:
            Image(systemName: "play.fill").font(.system(size: FocusMetrics.outputGlyphSize)).foregroundStyle(.orange)
        case .jobSucceeded:
            Image(systemName: "checkmark.circle.fill").font(.system(size: FocusMetrics.outputCircleGlyphSize)).foregroundStyle(.green)
        case .jobFailed, .error:
            Image(systemName: "xmark.circle.fill").font(.system(size: FocusMetrics.outputCircleGlyphSize)).foregroundStyle(.red)
        case .plain:
            Color.clear
        }
    }

    private var highlighted: AttributedString {
        var text = AttributedString(line.displayText)
        let characters = text.characters
        for range in matches {
            guard range.upperBound <= characters.count else { continue }
            let lower = characters.index(characters.startIndex, offsetBy: range.lowerBound)
            let upper = characters.index(characters.startIndex, offsetBy: range.upperBound)
            text[lower..<upper].backgroundColor = Color.accentColor.opacity(range == currentMatch ? 0.5 : 0.25)
        }
        return text
    }

    private var accessibilityText: String {
        let meaning: String? = switch line.kind {
        case .connected: "connected"
        case .jobStarted: "job started"
        case .jobSucceeded: "job succeeded"
        case .jobFailed: "job failed"
        case .error: "error"
        case .plain: nil
        }
        return [line.clockText.isEmpty ? nil : line.clockText, meaning, line.displayText].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The live line's block cursor. Blinks only when motion is allowed.
private struct Cursor: View {
    let blinks: Bool

    var body: some View {
        if blinks {
            TimelineView(.periodic(from: .now, by: FocusMetrics.cursorBlinkInterval)) { timeline in
                block.opacity(Int(timeline.date.timeIntervalSinceReferenceDate / FocusMetrics.cursorBlinkInterval).isMultiple(of: 2) ? 1 : 0)
            }
        } else {
            block
        }
    }

    private var block: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(FocusColor.tertiary)
            .frame(width: FocusMetrics.cursorSize.width, height: FocusMetrics.cursorSize.height)
            .accessibilityHidden(true)
    }
}
