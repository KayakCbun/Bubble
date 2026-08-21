import AppKit
import BubbleMounts
import SwiftUI

enum OverlayMetrics {
    static let inputWidth: CGFloat = 520
    static let transcriptWidthDefault: CGFloat = 760
    static let transcriptWidthWide: CGFloat = 1060
    static let transcriptInset: CGFloat = 24
    static let cornerRadius: CGFloat = 22
    static let transcriptCornerRadius: CGFloat = 18
    static let dockGap: CGFloat = 24
    static let minHeight: CGFloat = 46
    /// Padding around cards so the drop shadow is not clipped into a rectangle.
    static let shadowInset: CGFloat = 36
    static let chipHeight: CGFloat = 32
    static let stackSpacing: CGFloat = 8
    static let avatarSize: CGFloat = 28
    static let pickerWidth: CGFloat = 40
    static let pickerLeading: CGFloat = 6
    static let pickerHeight: CGFloat = 346
    static let fontSize: CGFloat = 13
    static let heading1Size: CGFloat = 16
    static let heading2Size: CGFloat = 14
    static let heading3Size: CGFloat = 13
    static let codeSize: CGFloat = 12
    static let chipSize: CGFloat = 12
    static var bodyFont: Font { .system(size: fontSize, weight: .regular) }
    static let slashRowHeight: CGFloat = 44
    static let paletteVisibleLimit = 7
    static let mountPaletteVisibleRows = 9
    static var ink: Color { Color(nsColor: .textColor) }
    static var tertiaryInk: Color { Color(nsColor: .tertiaryLabelColor) }

    static func transcriptWidth(wide: Bool) -> CGFloat {
        wide ? transcriptWidthWide : transcriptWidthDefault
    }

    static let previewWidth: CGFloat = 440

    static var transcriptMaxHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        return max(560, (visible * 0.70).rounded())
    }
    static var maxHeight: CGFloat {
        transcriptMaxHeight + stackSpacing + pickerHeight + stackSpacing + OverlayComposer.ceilingHeight
    }
}

struct OverlayView: View {
    @Bindable var store: ChatStore
    var onEscape: () -> Void
    var onToggleWidth: () -> Void

    @FocusState private var focused: Bool
    @State private var transcriptContentHeight: CGFloat = 0
    @State private var expandedThoughts: Set<UUID> = []
    @State private var expandedToolGroups: Set<String> = []
    @State private var expandedTools: Set<UUID> = []
    @State private var expandedWorkspaceRuns: Set<UUID> = []
    @State private var followLatest = true
    @State private var followQueued = false
    @StateObject private var ime = IMEComposingMonitor()

    private var inputShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: OverlayMetrics.cornerRadius, style: .continuous)
    }

    private var transcriptShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: OverlayMetrics.transcriptCornerRadius, style: .continuous)
    }

    private var transcriptHeight: CGFloat {
        OverlayLayoutPolicy.transcriptHeight(
            isPresented: isTranscriptPresented,
            maximum: OverlayMetrics.transcriptMaxHeight
        )
    }

    private var previewWidth: CGFloat {
        store.markdownPreview == nil ? 0 : OverlayMetrics.previewWidth
    }

    private var isTranscriptPresented: Bool {
        OverlayLayoutPolicy.isTranscriptPresented(
            itemCount: store.visibleItems.count,
            isStartingSession: store.isStartingSession
        ) || store.markdownPreview != nil
    }

    private var pickerHeight: CGFloat {
        store.showAvatarPicker ? OverlayMetrics.pickerHeight : 0
    }

    private var slashPaletteHeight: CGFloat {
        store.slashPaletteHeight
    }

    private var composerHeight: CGFloat {
        OverlayComposer.composerHeight(
            draft: store.draft,
            minHeight: OverlayMetrics.minHeight,
            avatarSize: OverlayMetrics.avatarSize,
            workspaceChip: store.activeWorkspaceBrief?.isActive == true,
            chipHeight: OverlayMetrics.chipHeight,
            attachmentCount: store.draftClips.count + store.draftImages.count,
            fieldWidth: OverlayComposer.fieldWidth(
                inputWidth: OverlayMetrics.inputWidth,
                avatarSize: OverlayMetrics.avatarSize
            ),
            fontSize: OverlayMetrics.fontSize
        )
    }

    private var conversationHeight: CGFloat {
        var height = composerHeight
        if isTranscriptPresented {
            height += OverlayMetrics.stackSpacing + transcriptHeight
        }
        return height
    }

    private var totalHeight: CGFloat {
        let pickerNeed = pickerHeight > 0
            ? composerHeight + OverlayMetrics.stackSpacing + pickerHeight
            : 0
        let slashNeed = slashPaletteHeight > 0
            ? composerHeight + OverlayMetrics.stackSpacing + slashPaletteHeight
            : 0
        return max(conversationHeight, pickerNeed, slashNeed)
    }

    private var chatWidth: CGFloat {
        OverlayMetrics.transcriptWidth(wide: store.transcriptWide)
    }

    private var layout: OverlayLayout {
        OverlayLayout(
            totalHeight: totalHeight,
            transcriptHeight: transcriptHeight,
            pickerHeight: pickerHeight,
            commandPaletteHeight: slashPaletteHeight,
            transcriptWidth: chatWidth,
            composerHeight: composerHeight,
            previewWidth: previewWidth
        )
    }

    var body: some View {
        VStack(alignment: .center, spacing: OverlayMetrics.stackSpacing) {
            if isTranscriptPresented {
                HStack(alignment: .top, spacing: OverlayMetrics.stackSpacing) {
                    transcriptList
                        .frame(width: chatWidth, height: transcriptHeight)
                        .frostedGlass(in: transcriptShape)
                        .overlay(alignment: .topTrailing) {
                            HStack(spacing: 2) {
                                TranscriptPinButton(pinned: store.overlayPinned) {
                                    store.toggleOverlayPin()
                                }
                                TranscriptWidthButton(wide: store.transcriptWide) {
                                    onToggleWidth()
                                }
                            }
                            .padding(.trailing, 6)
                            .padding(.top, 6)
                        }
                    if let preview = store.markdownPreview {
                        markdownPreviewPane(preview)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(OverlayMotion.panel, value: store.markdownPreview?.path)
            }
            VStack(spacing: 8) {
                if let brief = store.activeWorkspaceBrief, brief.isActive {
                    workspaceChip(brief)
                }
                composerAttachments
                inputRow
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: OverlayMetrics.inputWidth, height: composerHeight)
            .frostedGlass(in: inputShape)
            .overlay(alignment: .bottom) {
                Group {
                    if store.showAvatarPicker {
                        pickerStrip
                            .offset(y: -(composerHeight + OverlayMetrics.stackSpacing))
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity.combined(with: .offset(y: 8))
                            ))
                    } else if store.slashMenuVisible {
                        slashPalette
                            .offset(y: -(composerHeight + OverlayMetrics.stackSpacing))
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity.combined(with: .offset(y: 6))
                            ))
                    }
                }
                .animation(OverlayMotion.snappy, value: store.showAvatarPicker)
                .animation(OverlayMotion.quick, value: store.slashMenuVisible)
            }
        }
        .animation(OverlayMotion.panel, value: store.markdownPreview?.path)
        .frame(maxWidth: .infinity, alignment: .bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(OverlayMetrics.shadowInset)
        .environment(\.openMarkdownPreview) { path in
            store.openMarkdownPreview(path)
        }
        .preference(key: OverlayLayoutKey.self, value: layout)
        .background(Color.clear)
        .containerBackground(.clear, for: .window)
        .onAppear {
            restoreFocus()
            ime.start()
        }
        .onDisappear {
            ime.stop()
        }
        .onChange(of: store.focusTick) { _, _ in
            restoreFocus()
        }
        .onChange(of: store.isBusy) { _, _ in
            restoreFocus()
        }
        .onChange(of: store.items.count) { _, _ in
            restoreFocus()
        }
        .onChange(of: store.draft) { _, _ in
            ime.refresh()
            let count = store.visiblePaletteItems.count
            if count == 0 {
                store.slashHighlight = 0
            } else if store.slashHighlight >= count {
                store.slashHighlight = 0
            }
        }
        .onKeyPress(.escape) {
            if store.markdownPreview != nil {
                store.closeMarkdownPreview()
                return .handled
            }
            if ImageZoomController.shared.isVisible {
                ImageZoomController.shared.close()
                return .handled
            }
            if MermaidZoomController.shared.isVisible {
                MermaidZoomController.shared.close()
                return .handled
            }
            if store.slashMenuVisible {
                store.dismissSlashMenu()
            } else if store.showAvatarPicker {
                store.showAvatarPicker = false
            } else if store.isBusy {
                store.cancel()
            } else {
                onEscape()
            }
            return .handled
        }
    }

    private func markdownPreviewPane(_ document: MarkdownDocument) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.25, green: 0.55, blue: 0.95))
                Text(document.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 56)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().opacity(0.28)
            if let error = document.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error)
                        .font(.system(size: OverlayMetrics.fontSize))
                    Text(document.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)
            } else {
                ScrollView {
                    MessageBody(text: document.source, preferClassicMarkdown: true)
                        .padding(16)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(width: OverlayMetrics.previewWidth, height: transcriptHeight)
        .frostedGlass(in: transcriptShape)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                PreviewChromeButton(symbol: "folder", help: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: document.path)])
                }
                PreviewChromeButton(symbol: "xmark", help: "Close preview") {
                    store.closeMarkdownPreview()
                }
            }
            .padding(.trailing, 6)
            .padding(.top, 6)
        }
    }

    private var historyTicks: [HistoryTick] {
        HistoryPreview.ticks(from: store.visibleItems)
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.lastTurnDuration >= 1, !store.isBusy {
                        workedHeader(store.lastTurnDuration)
                    }
                    ForEach(displayRows) { row in
                        transcriptRow(row)
                            .id(row.id)
                    }
                    if store.isBusy {
                        WorkingRow(startedAt: store.turnStartedAt ?? Date())
                            .id("working")
                    }
                    Color.clear
                        .frame(height: OverlayMetrics.transcriptCornerRadius)
                        .id("transcript-end")
                }
                .padding(.leading, historyTicks.isEmpty ? OverlayMetrics.transcriptInset : HistoryLimits.gutter + 16)
                .padding(.trailing, OverlayMetrics.transcriptInset)
                .padding(.top, OverlayMetrics.transcriptInset)
                .padding(.bottom, 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(OverlayMetrics.ink)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: TranscriptContentHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .contentMargins(.bottom, 0, for: .scrollContent)
            .transaction { transaction in
                if store.isBusy {
                    transaction.disablesAnimations = true
                }
            }
            .overlay {
                if store.isStartingSession {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Starting Bubble")
                }
            }
            .overlay(alignment: .leading) {
                if !historyTicks.isEmpty {
                    HistoryTickRail(
                        ticks: historyTicks,
                        viewportHeight: transcriptHeight
                    ) { id in
                        followLatest = false
                        OverlayPulse.shared.onNextFrame {
                            withAnimation(OverlayMotion.scroll) {
                                proxy.scrollTo(id.uuidString, anchor: .top)
                            }
                        }
                    }
                }
            }
            .onPreferenceChange(TranscriptContentHeightKey.self) { height in
                if abs(height - transcriptContentHeight) > 0.5 {
                    transcriptContentHeight = height
                }
                requestFollowLatest(proxy)
            }
            .onAppear { requestFollowLatest(proxy) }
            .onChange(of: store.items.count) { _, _ in
                if store.items.last?.kind == .user {
                    followLatest = true
                }
                requestFollowLatest(proxy)
            }
            .onChange(of: store.items.last?.text) { _, _ in
                requestFollowLatest(proxy)
            }
            .onChange(of: store.items.last?.toolStatus) { _, _ in
                requestFollowLatest(proxy)
            }
            .onChange(of: store.isBusy) { _, _ in
                requestFollowLatest(proxy)
            }
            .onChange(of: transcriptContentHeight) { _, _ in
                requestFollowLatest(proxy)
            }
        }
    }

    private var slashPalette: some View {
        let items = store.visiblePaletteItems
        return VStack(alignment: .leading, spacing: 2) {
            Text(store.paletteCaption)
                .font(OverlayMetrics.bodyFont)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 4)
            if store.isAppPalette {
                appSearchField
            }
            if store.isMountPalette {
                mountSearchField
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            paletteRow(item, highlighted: index == store.slashHighlight)
                                .id(index)
                                .animation(OverlayMotion.quick, value: store.slashHighlight)
                        }
                    }
                }
                .scrollIndicators(items.count > OverlayMetrics.mountPaletteVisibleRows ? .visible : .hidden)
                .frame(height: paletteListHeight(for: items.count))
                .onChange(of: store.slashHighlight) { _, index in
                    OverlayPulse.shared.onNextFrame {
                        withAnimation(OverlayMotion.quick) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
                .onChange(of: items.count) { _, _ in
                    OverlayPulse.shared.onNextFrame {
                        proxy.scrollTo(store.slashHighlight, anchor: .center)
                    }
                }
            }
        }
        .padding(8)
        .frame(width: OverlayMetrics.inputWidth, alignment: .leading)
        .frostedGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var appSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("Search apps", text: appSearchBinding)
                .textFieldStyle(.plain)
                .font(OverlayMetrics.bodyFont)
                .onSubmit {
                    if let item = store.visiblePaletteItems.first {
                        store.selectPalette(item)
                        restoreFocus()
                    }
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    private var appSearchBinding: Binding<String> {
        Binding(
            get: { BubbleComposer.argumentQuery(command: "open", in: store.draft) ?? "" },
            set: { store.draft = "/open \($0)" }
        )
    }

    private var mountSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("Open a folder", text: mountSearchBinding)
                .textFieldStyle(.plain)
                .font(OverlayMetrics.bodyFont)
                .onSubmit {
                    store.toggleHighlightedMount()
                    restoreFocus()
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    private func paletteListHeight(for count: Int) -> CGFloat {
        let shown = store.isMountPalette
            ? min(count, OverlayMetrics.mountPaletteVisibleRows)
            : count
        return CGFloat(max(shown, 1)) * OverlayMetrics.slashRowHeight
    }

    private var mountSearchBinding: Binding<String> {
        Binding(
            get: { BubbleComposer.argumentQuery(command: "mounts", in: store.draft) ?? "" },
            set: { store.draft = "/mounts \($0)" }
        )
    }

    private func mountBadge(_ state: String) -> some View {
        Image(systemName: mountBadgeSymbol(state))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(state == "running" || state == "waiting" ? Color.accentColor : Color.secondary)
    }

    private func mountBadgeSymbol(_ state: String) -> String {
        switch state {
        case "running": "arrow.trianglehead.2.clockwise"
        case "waiting": "questionmark.circle"
        case "mounted": "checkmark.circle"
        default: "circle"
        }
    }

    private func workspaceChip(_ brief: WorkspaceBrief) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .semibold))
            Text(brief.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            if brief.status == .running {
                RunningSweepLabel()
            } else {
                Text(brief.status.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct RunningSweepLabel: View {
        private let label = "running"
        private let font = Font.system(size: 11, weight: .medium)

        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: false)) { context in
                let cycle = 2.05
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
                let raw = min(1, t / 1.45)
                let eased = raw * raw * (3 - 2 * raw)
                Text(label)
                    .font(font)
                    .foregroundStyle(.tertiary)
                    .overlay {
                        Text(label)
                            .font(font)
                            .foregroundStyle(Color.primary.opacity(0.78))
                            .mask {
                                GeometryReader { geo in
                                    let width = geo.size.width
                                    let band = max(18, width * 0.62)
                                    let travel = width + band
                                    LinearGradient(
                                        colors: [
                                            .clear,
                                            Color.white.opacity(0.35),
                                            .white,
                                            Color.white.opacity(0.35),
                                            .clear,
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                    .frame(width: band, height: geo.size.height)
                                    .offset(x: -band + CGFloat(eased) * travel)
                                }
                            }
                    }
            }
        }
    }

    private func paletteRow(_ item: PaletteItem, highlighted: Bool) -> some View {
        let showEnter = item.kind == .mount && item.role == "enter"
        let badge = item.kind == .mount ? item.badge : nil
        let showBadge = !(badge ?? "").isEmpty
        return HStack(alignment: .center, spacing: 0) {
            Button {
                store.selectPalette(item)
                restoreFocus()
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    paletteLeading(item)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(item.title)
                                .font(OverlayMetrics.bodyFont)
                                .lineLimit(1)
                            if let hint = item.hint, !hint.isEmpty {
                                Text(hint)
                                    .font(OverlayMetrics.bodyFont)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        if !item.subtitle.isEmpty {
                            Text(item.subtitle)
                                .font(OverlayMetrics.bodyFont)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if showEnter {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 22, height: 28)
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, showBadge ? 0 : 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showBadge, let badge {
                Button {
                    store.handleMountBadge(item)
                    restoreFocus()
                } label: {
                    mountBadge(badge)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(badge == "unmounted" ? "Mount" : "Unmount")
                .padding(.trailing, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(highlighted ? Color.primary.opacity(0.08) : Color.clear)
        )
    }

    @ViewBuilder
    private func paletteLeading(_ item: PaletteItem) -> some View {
        if item.kind == .app, let path = item.artworkPath {
            Image(nsImage: MacApps.icon(forPath: path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: paletteIcon(for: item))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
    }

    private func paletteIcon(for item: PaletteItem) -> String {
        if item.kind == .mount {
            switch item.role {
            case "up": return "arrow.uturn.up"
            case "browse": return "folder.badge.plus"
            case "toggle": return "folder.badge.checkmark"
            default: return "folder"
            }
        }
        switch item.kind {
        case .command: return "chevron.left.forwardslash.chevron.right"
        case .skill: return "sparkles"
        case .template: return "doc.plaintext"
        case .file: return "doc"
        case .model: return "cpu"
        case .thinking: return "brain"
        case .app: return "app"
        case .clipboard: return "doc.on.clipboard"
        case .mount: return "folder"
        }
    }

    private var pickerStrip: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: OverlayMetrics.pickerLeading, height: OverlayMetrics.pickerHeight)
            AvatarPickerView(selectedFile: store.selectedAvatarFile) { file in
                store.selectAvatar(file)
            }
            .frame(width: OverlayMetrics.pickerWidth, height: OverlayMetrics.pickerHeight)
            .frostedGlass(in: Capsule())
            Spacer(minLength: 0)
        }
        .frame(
            width: OverlayMetrics.inputWidth,
            height: OverlayMetrics.pickerHeight,
            alignment: .bottomLeading
        )
        .fixedSize(horizontal: false, vertical: true)
        .zIndex(1)
    }

    @ViewBuilder
    private var composerAttachments: some View {
        if !store.draftClips.isEmpty || !store.draftImages.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.draftImages) { image in
                        draftImageChip(image)
                    }
                    ForEach(store.draftClips) { clip in
                        draftClipChip(clip)
                    }
                }
            }
            .frame(height: OverlayComposer.attachmentRow)
        }
    }

    private func draftImageChip(_ image: DraftImage) -> some View {
        ZStack(alignment: .topTrailing) {
            if let nsImage = NSImage(data: image.png) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(.secondary)
            }
            Button {
                store.removeDraftImage(image.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
            .help("Remove image")
        }
        .padding(.top, 4)
        .padding(.trailing, 4)
    }

    private func draftClipChip(_ clip: DraftClip) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 11, weight: .semibold))
            Text(OverlayComposer.clipLabel(clip.text))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Button {
                store.removeDraftClip(clip.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove pasted text")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var inputRow: some View {
        let lineCount = OverlayComposer.visibleLineCount(
            store.draft,
            fieldWidth: OverlayComposer.fieldWidth(
                inputWidth: OverlayMetrics.inputWidth,
                avatarSize: OverlayMetrics.avatarSize
            ),
            fontSize: OverlayMetrics.fontSize
        )
        let fieldHeight = max(
            OverlayMetrics.avatarSize,
            CGFloat(lineCount) * OverlayComposer.lineHeight
        )
        return HStack(alignment: .center, spacing: 8) {
            FxAvatarView(
                file: store.selectedAvatarFile,
                animation: store.isBusy ? "working" : "idle",
                onTap: { store.toggleAvatarPicker() }
            )
            .frame(width: OverlayMetrics.avatarSize, height: OverlayMetrics.avatarSize)

            ZStack(alignment: lineCount > 1 ? .topLeading : .leading) {
                TextField("", text: $store.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(OverlayMetrics.bodyFont)
                    .foregroundStyle(OverlayMetrics.ink)
                    .focused($focused)
                    .lineLimit(1...OverlayComposer.maxVisibleLines)
                    .submitLabel(.send)
                    .onSubmit {
                        if store.isMountPalette, store.slashMenuVisible {
                            store.toggleHighlightedMount()
                        } else {
                            store.send()
                        }
                        restoreFocus()
                    }
                if showInputPlaceholder {
                    HStack(spacing: 3) {
                        if showInputCaret {
                            InputCaret()
                        }
                        Text(store.draftImages.isEmpty && store.draftClips.isEmpty
                             ? "Ask Bubble  /  @  $"
                             : "Add a caption")
                            .font(OverlayMetrics.bodyFont)
                            .foregroundStyle(OverlayMetrics.tertiaryInk)
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(
                minHeight: OverlayMetrics.avatarSize,
                maxHeight: fieldHeight,
                alignment: lineCount > 1 ? .topLeading : .center
            )
            .fixedSize(horizontal: false, vertical: lineCount == 1)

            if showComposerStop {
                Button {
                    stopComposer()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(store.activeWorkspaceBrief?.isActive == true ? "Stop workspace run" : "Stop")
                .accessibilityLabel(store.activeWorkspaceBrief?.isActive == true ? "Stop workspace run" : "Stop")
            } else if store.hasComposerPayload {
                Button {
                    store.send()
                    restoreFocus()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
        }
    }

    private var displayRows: [TranscriptRow] {
        groupedRows(from: store.visibleItems, collapsePrefix: "collapsed")
    }

    private func groupedRows(from items: [ChatItem], collapsePrefix: String) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var tools: [ChatItem] = []
        func flushTools() {
            guard !tools.isEmpty else { return }
            let latest = tools.removeLast()
            rows.append(.tool(latest))
            if !tools.isEmpty {
                rows.append(.collapsedTools(
                    id: "\(collapsePrefix)-\(latest.id.uuidString)",
                    items: tools
                ))
            }
            tools = []
        }
        for item in items {
            if item.kind == .tool {
                tools.append(item)
            } else {
                flushTools()
                rows.append(.message(item))
            }
        }
        flushTools()
        return rows
    }

    private var showInputPlaceholder: Bool {
        store.draft.isEmpty && !ime.composing && !store.isBusy
    }

    private var showInputCaret: Bool {
        focused && showInputPlaceholder
    }

    private var showComposerStop: Bool {
        store.isBusy || store.activeWorkspaceBrief?.isActive == true
    }

    private func stopComposer() {
        if store.activeWorkspaceBrief?.isActive == true {
            store.cancelWorkspaceRun()
        } else {
            store.cancel()
        }
    }

    private func restoreFocus() {
        focused = true
        DispatchQueue.main.async {
            self.focused = true
            self.activateFieldEditor()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            self.focused = true
            self.activateFieldEditor()
        }
    }

    private func activateFieldEditor() {
        guard let window = NSApp.windows.first(where: { $0 is OverlayPanel && $0.isVisible }) else {
            return
        }
        window.makeKey()
        if let textView = window.firstResponder as? NSTextView, textView.isEditable {
            textView.insertionPointColor = .textColor
            return
        }
        if let target = firstEditableText(in: window.contentView) {
            window.makeFirstResponder(target)
            if let textView = window.firstResponder as? NSTextView {
                textView.insertionPointColor = .textColor
            }
        }
    }

    private func firstEditableText(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView, textView.isEditable {
            return textView
        }
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for child in view.subviews {
            if let found = firstEditableText(in: child) {
                return found
            }
        }
        return nil
    }

    private func requestFollowLatest(_ proxy: ScrollViewProxy) {
        guard followLatest, !followQueued else { return }
        followQueued = true
        OverlayPulse.shared.onNextFrame {
            followQueued = false
            guard followLatest else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo("transcript-end", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func transcriptRow(_ row: TranscriptRow) -> some View {
        switch row {
        case .message(let item):
            switch item.kind {
            case .user:
                userBubble(item)
            case .assistant:
                assistantBubble(item)
            case .thought:
                thoughtBlock(item)
            case .system:
                quoteCard(item.text)
            case .workspaceRun:
                workspaceRunCard(item)
            default:
                EmptyView()
            }
        case .tool(let item):
            toolRow(item)
        case .collapsedTools(let id, let items):
            collapsedTools(id: id, items: items)
        }
    }

    private func workedHeader(_ duration: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Worked for \(formatDuration(duration))")
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .font(.system(size: OverlayMetrics.fontSize, weight: .regular))
            .foregroundStyle(.secondary)
            Divider().opacity(0.45)
        }
    }

    private func userBubble(_ item: ChatItem) -> some View {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = item.imageNames ?? []
        return HStack {
            Spacer(minLength: 72)
            VStack(alignment: .trailing, spacing: 8) {
                if !names.isEmpty {
                    VStack(alignment: .trailing, spacing: 8) {
                        ForEach(names, id: \.self) { name in
                            userImageThumb(name)
                        }
                    }
                }
                if !text.isEmpty {
                    Text(text)
                        .font(OverlayMetrics.bodyFont)
                        .foregroundStyle(OverlayMetrics.ink)
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, names.isEmpty ? 16 : 10)
            .padding(.vertical, names.isEmpty ? 12 : 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
        }
    }

    private func userImageThumb(_ name: String) -> some View {
        let image = BubbleImages.load(name)
        return Button {
            if let image {
                ImageZoomController.shared.show(image)
            }
        } label: {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 120, height: 80)
                }
            }
            .frame(maxWidth: 260, maxHeight: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("View image")
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    private func assistantBubble(_ item: ChatItem) -> some View {
        let live = store.isBusy && store.streamingAssistantId == item.id
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                MessageBody(text: item.text, streaming: live)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if live {
                    StreamingCaret()
                }
            }
            if !live, !text.isEmpty {
                AssistantCopyButton(text: text)
            }
        }
    }

    private func quoteCard(_ text: String) -> some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let title = lines.first ?? text
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemSymbol(title))
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(3)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tertiary)
            if !body.isEmpty {
                Text(body)
                    .font(.system(size: 12.5, weight: .regular))
                    .lineSpacing(4)
                    .foregroundStyle(.secondary.opacity(0.88))
                    .textSelection(.enabled)
                    .padding(.leading, 18)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func systemSymbol(_ title: String) -> String {
        let text = title.lowercased()
        if text.hasPrefix("mounted") { return "folder.badge.plus" }
        if text.hasPrefix("unmounted") { return "folder.badge.minus" }
        if text.contains("model") { return "cpu" }
        if text.contains("thinking") { return "brain" }
        if text.hasPrefix("opening") || text.hasPrefix("open") { return "app" }
        if text.hasPrefix("copied") { return "doc.on.clipboard" }
        if text.contains("ready") { return "checkmark" }
        if text.contains("reconnect") { return "arrow.trianglehead.2.clockwise" }
        return "info.circle"
    }

    private func thoughtBlock(_ item: ChatItem) -> some View {
        let live = store.isBusy && store.streamingThoughtId == item.id
        let open = live || expandedThoughts.contains(item.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if live { return }
                withAnimation(OverlayMotion.snappy) {
                    if open {
                        expandedThoughts.remove(item.id)
                    } else {
                        expandedThoughts.insert(item.id)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 8)
                    Image(systemName: "quote.opening")
                        .font(.system(size: 10, weight: .semibold))
                    Text(live ? "Thinking" : "Thoughts")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                HStack(alignment: .top, spacing: 10) {
                    Capsule()
                        .fill(Color.primary.opacity(0.16))
                        .frame(width: 2)
                    Text(item.text.isEmpty && live ? "…" : item.text)
                        .font(.system(size: 12.5, weight: .regular))
                        .italic()
                        .lineSpacing(3)
                        .foregroundStyle(.secondary.opacity(0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.leading, 14)
            }
        }
        .padding(.vertical, 2)
        .opacity(0.92)
    }

    private func workspaceRunCard(_ item: ChatItem) -> some View {
        let status = item.workspaceStatus ?? "running"
        let live = status == "running"
        let open = live || expandedWorkspaceRuns.contains(item.id)
        let summary = item.workspaceSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    if live { return }
                    withAnimation(OverlayMotion.snappy) {
                        if open {
                            expandedWorkspaceRuns.remove(item.id)
                        } else {
                            expandedWorkspaceRuns.insert(item.id)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 8)
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .semibold))
                        Text(item.workspaceName ?? item.text)
                            .lineLimit(1)
                        Text(status)
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if status == "running" || status == "waiting" {
                    Button {
                        store.cancelWorkspaceRun()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Stop workspace run")
                }
            }
            if !summary.isEmpty {
                if open {
                    MessageBody(text: summary)
                        .padding(.leading, 18)
                } else {
                    Text(workspacePreview(summary))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.leading, 18)
                }
            }
            if open, let children = item.workspaceChildren, !children.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(groupedRows(from: children, collapsePrefix: "ws-\(item.id.uuidString)")) { row in
                        workspaceChildRow(row)
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(.vertical, 2)
        .opacity(0.92)
    }

    private func workspacePreview(_ text: String) -> String {
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty && !line.hasPrefix("#")
            }
        let picked = lines.prefix(2).joined(separator: " ")
        return picked.isEmpty ? String(text.prefix(160)) : picked
    }

    @ViewBuilder
    private func workspaceChildRow(_ row: TranscriptRow) -> some View {
        switch row {
        case .tool(let item):
            toolRow(item)
        case .collapsedTools(let id, let items):
            collapsedTools(id: id, items: items)
        case .message(let item):
            thoughtBlock(item)
        }
    }

    private func toolRow(_ item: ChatItem) -> some View {
        let status = item.toolStatus ?? "pending"
        let open = expandedTools.contains(item.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(OverlayMotion.snappy) {
                    if open {
                        expandedTools.remove(item.id)
                    } else {
                        expandedTools.insert(item.id)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 8)
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Tool")
                    Text(item.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if status == "completed" {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                    } else if status == "failed" {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red.opacity(0.7))
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                HStack(alignment: .top, spacing: 10) {
                    Capsule()
                        .fill(Color.primary.opacity(0.16))
                        .frame(width: 2)
                    toolDetails(item)
                }
                .padding(.leading, 14)
            }
        }
        .padding(.vertical, 2)
        .opacity(0.92)
    }

    @ViewBuilder
    private func toolDetails(_ item: ChatItem) -> some View {
        let input = item.toolInput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let output = item.toolOutput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        VStack(alignment: .leading, spacing: 8) {
            if !input.isEmpty {
                Text("Input")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(input)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !output.isEmpty {
                Text("Output")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(output)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if input.isEmpty && output.isEmpty {
                Text("No input/output captured for this tool call.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func collapsedTools(id: String, items: [ChatItem]) -> some View {
        let open = expandedToolGroups.contains(id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(OverlayMotion.snappy) {
                    if open {
                        expandedToolGroups.remove(id)
                    } else {
                        expandedToolGroups.insert(id)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 8)
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("+\(items.count) previous tool call\(items.count == 1 ? "" : "s")")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(items) { item in
                    toolRow(item)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(0.92)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let minutes = seconds / 60
        let remain = seconds % 60
        if minutes == 0 {
            return "\(remain)s"
        }
        return "\(minutes)m \(remain)s"
    }
}

private struct AssistantCopyButton: View {
    var text: String
    @State private var copied = false
    @State private var hovered = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "square.on.square")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(copied || hovered ? OverlayMetrics.ink.opacity(0.72) : Color.secondary.opacity(0.78))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy this reply")
        .accessibilityLabel("Copy reply")
        .onHover { hovering in
            hovered = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    private func copy() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copied = false
        }
    }
}

private struct PreviewChromeButton: View {
    var symbol: String
    var help: String
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovered ? 1 : 0.55)
        .animation(OverlayMotion.quick, value: hovered)
        .onHover { hovered = $0 }
        .help(help)
    }
}

private struct TranscriptPinButton: View {
    var pinned: Bool
    var onToggle: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(pinned || hovered ? 1 : 0.55)
        .animation(OverlayMotion.quick, value: hovered)
        .animation(OverlayMotion.quick, value: pinned)
        .onHover { hovered = $0 }
        .help(pinned ? "Unpin" : "Keep Bubble visible")
        .accessibilityLabel(pinned ? "Unpin Bubble" : "Pin Bubble")
    }
}

private struct TranscriptWidthButton: View {
    var wide: Bool
    var onToggle: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: wide
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovered ? 1 : 0.55)
        .animation(OverlayMotion.quick, value: hovered)
        .onHover { hovered = $0 }
        .help(wide ? "Default width" : "Wider")
        .accessibilityLabel(wide ? "Default width" : "Wider")
    }
}

private enum TranscriptRow: Identifiable {
    case message(ChatItem)
    case tool(ChatItem)
    case collapsedTools(id: String, items: [ChatItem])

    var id: String {
        switch self {
        case .message(let item):
            item.id.uuidString
        case .tool(let item):
            "tool-\(item.id.uuidString)"
        case .collapsedTools(let id, _):
            id
        }
    }
}

private struct WorkingRow: View {
    var startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                WorkingDots()
                Text("Working for \(format(context.date.timeIntervalSince(startedAt)))")
                    .font(.system(size: OverlayMetrics.fontSize, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let minutes = seconds / 60
        let remain = seconds % 60
        if minutes == 0 {
            return "\(remain)s"
        }
        return "\(minutes)m \(remain)s"
    }
}

private struct WorkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = 0.5 + 0.5 * sin((t * 2.2) - Double(index) * 0.7)
                    Circle()
                        .fill(Color.secondary.opacity(0.22 + 0.63 * wave))
                        .frame(width: 5, height: 5)
                }
            }
        }
    }
}

private struct FrostedGlass<S: Shape>: ViewModifier {
    var shape: S
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        let fill = dark
            ? Color(red: 0.16, green: 0.16, blue: 0.17)
            : Color.white
        content
            .clipShape(shape)
            .background {
                shape
                    .fill(fill)
                    .shadow(
                        color: Color.black.opacity(dark ? 0.32 : 0.055),
                        radius: 18,
                        y: 14
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                if dark {
                    shape.stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            }
    }
}

private extension View {
    func frostedGlass<S: Shape>(in shape: S) -> some View {
        modifier(FrostedGlass(shape: shape))
    }
}

final class IMEComposingMonitor: ObservableObject {
    @Published var composing = false
    private var tokens: [NSObjectProtocol] = []
    private var eventMonitor: Any?

    func start() {
        guard tokens.isEmpty else {
            refresh()
            return
        }
        let center = NotificationCenter.default
        let names = [
            NSText.didChangeNotification,
            NSTextView.didChangeSelectionNotification,
            NSControl.textDidChangeNotification,
        ]
        for name in names {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.refresh()
            return event
        }
        refresh()
    }

    func stop() {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens.removeAll()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        composing = false
    }

    func refresh() {
        let window = NSApp.windows.first(where: { $0 is OverlayPanel && $0.isVisible })
        let next = isComposing(in: window)
        if next != composing {
            composing = next
        }
    }

    private func isComposing(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        if let textView = window.firstResponder as? NSTextView, occupied(textView) {
            return true
        }
        return hasOccupiedTextView(in: window.contentView)
    }

    private func hasOccupiedTextView(in view: NSView?) -> Bool {
        guard let view else { return false }
        if let textView = view as? NSTextView, occupied(textView) {
            return true
        }
        return view.subviews.contains { hasOccupiedTextView(in: $0) }
    }

    private func occupied(_ textView: NSTextView) -> Bool {
        textView.isEditable && textView.hasMarkedText()
    }
}

private struct InputCaret: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.5 + 0.5 * sin(t * .pi / 0.53)
            Capsule()
                .fill(Color.primary.opacity(0.12 + 0.78 * pulse))
                .frame(width: 1.5, height: 16)
        }
    }
}

private struct StreamingCaret: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = 0.5 + 0.5 * sin(t * .pi / 0.48)
            Capsule()
                .fill(Color.primary.opacity(0.16 + 0.7 * pulse))
                .frame(width: 1.6, height: 14)
                .offset(y: 1)
        }
    }
}

struct OverlayLayout: Equatable {
    var totalHeight: CGFloat
    var transcriptHeight: CGFloat
    var pickerHeight: CGFloat
    var commandPaletteHeight: CGFloat
    var transcriptWidth: CGFloat
    var composerHeight: CGFloat
    var previewWidth: CGFloat = 0
}

struct OverlayLayoutKey: PreferenceKey {
    static var defaultValue = OverlayLayout(
        totalHeight: 0,
        transcriptHeight: 0,
        pickerHeight: 0,
        commandPaletteHeight: 0,
        transcriptWidth: OverlayMetrics.transcriptWidthDefault,
        composerHeight: OverlayMetrics.minHeight,
        previewWidth: 0
    )
    static func reduce(value: inout OverlayLayout, nextValue: () -> OverlayLayout) {
        value = nextValue()
    }
}

struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TranscriptContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
