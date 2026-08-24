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

    static let previewWidth: CGFloat = 560

    static func fittedTranscriptWidth(
        wide: Bool,
        sideStageWidth: CGFloat,
        visibleWidth: CGFloat
    ) -> CGFloat {
        OverlayLayoutPolicy.fittedChatWidth(
            desired: transcriptWidth(wide: wide),
            sideStageWidth: sideStageWidth,
            visibleWidth: visibleWidth,
            gap: stackSpacing,
            bleed: shadowInset,
            minimum: inputWidth
        )
    }

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
        SideStagePolicy.width(
            showingMarkdown: store.markdownPreview != nil,
            showingWorkspace: store.workspaceStage != nil,
            markdownWidth: OverlayMetrics.previewWidth,
            workspaceWidth: OverlayMetrics.previewWidth
        )
    }

    private var isTranscriptPresented: Bool {
        OverlayLayoutPolicy.isTranscriptPresented(
            itemCount: store.visibleItems.count,
            isStartingSession: store.isStartingSession
        ) || store.sideStagePresented
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
            attachmentCount: store.draftClips.count + store.draftImages.count + (store.branchDraft == nil ? 0 : 1),
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
        OverlayMetrics.fittedTranscriptWidth(
            wide: store.transcriptWide,
            sideStageWidth: previewWidth,
            visibleWidth: store.visibleScreenWidth
        )
    }

    private var layout: OverlayLayout {
        OverlayLayout(
            totalHeight: totalHeight,
            transcriptHeight: transcriptHeight,
            pickerHeight: pickerHeight,
            commandPaletteHeight: slashPaletteHeight,
            transcriptWidth: chatWidth,
            composerHeight: composerHeight,
            previewWidth: previewWidth,
            chromeVisible: store.sideStageChromeVisible
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OverlayMetrics.stackSpacing) {
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
                    if store.sideStagePresented {
                        sideStagePane
                            .compositingGroup()
                            .opacity(SideStageChromePolicy.opacity(visible: store.sideStageChromeVisible))
                            .animation(
                                store.sideStageChromeVisible
                                    ? OverlayMotion.sideStageReveal
                                    : OverlayMotion.sideStageHide,
                                value: store.sideStageChromeVisible
                            )
                            .allowsHitTesting(store.sideStageChromeVisible)
                    }
                }
                .frame(maxWidth: .infinity, alignment: OverlayRenderPolicy.pinsConversationToLeadingEdge ? .leading : .center)
                .animation(
                    OverlayRenderPolicy.shouldAnimateSideStageContentLayout
                        ? OverlayMotion.panel
                        : nil,
                    value: store.sideStagePresented
                )
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
            .background(WindowDragArea())
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
            .frame(maxWidth: .infinity)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: OverlayRenderPolicy.pinsConversationToLeadingEdge ? .bottomLeading : .bottom
        )
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
            guard PromptTriggerPolicy.hasActiveTrigger(in: store.draft) else {
                if store.slashHighlight != 0 { store.slashHighlight = 0 }
                return
            }
            let count = store.visiblePaletteItems.count
            if count == 0 {
                store.slashHighlight = 0
            } else if store.slashHighlight >= count {
                store.slashHighlight = 0
            }
        }
        .onKeyPress(.escape) {
            if store.handleSideStageEscape() {
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

    @ViewBuilder
    private var sideStagePane: some View {
        ZStack {
            if let stage = store.workspaceStage {
                workspaceStageContent(stage)
                    .opacity(store.markdownPreview == nil ? 1 : 0)
                    .allowsHitTesting(store.markdownPreview == nil)
            }
            if let preview = store.markdownPreview {
                markdownPreviewPane(preview)
            }
        }
        .frame(width: previewWidth, height: transcriptHeight)
        .clipped()
        .environment(\.openMarkdownPreview) { path in
            store.openMarkdownPreview(path, fromWorkspacePane: store.workspaceStage != nil)
        }
    }

    @ViewBuilder
    private func workspaceStageContent(_ stage: WorkspaceStage) -> some View {
        switch SideStagePresentationPolicy.content(
            workspacePresented: store.workspaceStage != nil,
            phase: store.workspacePanePresentationPhase
        ) {
        case .hidden:
            EmptyView()
        case .placeholder:
            workspaceSessionPlaceholder(stage)
        case .transcript:
            workspaceSessionPane(stage)
        }
    }

    private func workspaceSessionPlaceholder(_ stage: WorkspaceStage) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .semibold))
                Text(stage.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().opacity(0.28)
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 46, height: 46)
                    .opacity(0.72)
                Text("Opening workspace…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: previewWidth, height: transcriptHeight)
        .frostedGlass(in: transcriptShape)
    }

    private func workspaceSessionPane(_ stage: WorkspaceStage) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .semibold))
                Text(stage.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let item = store.items.first(where: { $0.id == stage.cardId }),
                   let status = item.workspaceStatus {
                    if status == "running" {
                        RunningSweepLabel()
                    } else {
                        Text(status)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 36)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().opacity(0.28)
            workspaceTranscriptList
        }
        .frame(width: previewWidth, height: transcriptHeight)
        .frostedGlass(in: transcriptShape)
        .overlay(alignment: .topTrailing) {
            PreviewChromeButton(symbol: "xmark", help: "Close workspace session") {
                store.closeSideStage()
            }
            .padding(.trailing, 6)
            .padding(.top, 6)
        }
    }

    private var workspaceTranscriptList: some View {
        let rows = groupedRows(from: store.visibleWorkspacePaneItems, collapsePrefix: "ws-pane")
        let live = store.childBusy && store.workspaceStage?.path == store.activeWorkspaceBrief?.path
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(rows) { row in
                        Group {
                            switch row {
                            case .collapsedTools:
                                transcriptRow(row, interactive: false)
                            case .message, .tool:
                                EquatableSection(value: rowRenderKey(row)) {
                                    transcriptRow(row, interactive: false)
                                }
                                .equatable()
                            }
                        }
                        .id(workspaceRowScrollId(row))
                    }
                    if live, let started = store.items.first(where: { $0.id == store.workspaceStage?.cardId })?.workspaceStartedAt {
                        WorkingRow(startedAt: Date(timeIntervalSince1970: started))
                            .id("workspace-working")
                    }
                    Color.clear
                        .frame(height: OverlayMetrics.transcriptCornerRadius)
                        .id("workspace-end")
                }
                .padding(.horizontal, OverlayMetrics.transcriptInset)
                .padding(.top, OverlayMetrics.transcriptInset)
                .padding(.bottom, 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(OverlayMetrics.ink)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .onAppear { scrollWorkspacePane(proxy) }
            .onChange(of: store.workspacePaneScrollToken) { _, _ in
                scrollWorkspacePane(proxy)
            }
            .onChange(of: store.workspacePaneItems.count) { _, _ in
                followWorkspacePane(proxy)
            }
            .onChange(of: store.workspacePaneItems.last?.text) { _, _ in
                followWorkspacePane(proxy)
            }
            .onChange(of: store.workspacePaneItems.last?.toolStatus) { _, _ in
                followWorkspacePane(proxy)
            }
            .onChange(of: store.childBusy) { _, _ in
                followWorkspacePane(proxy)
            }
        }
    }

    private func workspaceRowScrollId(_ row: TranscriptRow) -> String {
        switch row {
        case .message(let item):
            if item.kind == .user, let entry = item.sourceEntryId, !entry.isEmpty {
                return "entry-\(entry)"
            }
            return item.id.uuidString
        case .tool(let item):
            return item.id.uuidString
        case .collapsedTools(let id, _):
            return id
        }
    }

    private func scrollWorkspacePane(_ proxy: ScrollViewProxy) {
        let follow = store.workspaceStage?.followLatest ?? true
        let target = SideStagePolicy.scrollTarget(
            followLatest: follow,
            anchorEntryId: store.workspaceStage?.anchorEntryId,
            rows: store.visibleWorkspacePaneItems.map(WorkspaceTurnRow.init)
        )
        OverlayPulse.shared.onNextFrame {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }

    private func followWorkspacePane(_ proxy: ScrollViewProxy) {
        guard store.workspaceStage?.followLatest == true else { return }
        OverlayPulse.shared.onNextFrame {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo("workspace-end", anchor: .bottom)
            }
        }
    }

    private func markdownPreviewPane(_ document: MarkdownDocument) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if store.canReturnToWorkspace {
                    PreviewChromeButton(symbol: "chevron.left", help: "Back to workspace session") {
                        store.returnToWorkspaceStage()
                    }
                }
                Image(systemName: "doc.richtext.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.25, green: 0.55, blue: 0.95))
                Text(document.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 56)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, store.canReturnToWorkspace ? 6 : 12)
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
        .frame(width: previewWidth, height: transcriptHeight)
        .frostedGlass(in: transcriptShape)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                PreviewChromeButton(symbol: "folder", help: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: document.path)])
                }
                PreviewChromeButton(symbol: "xmark", help: "Close preview") {
                    store.closeSideStage()
                }
            }
            .padding(.trailing, 6)
            .padding(.top, 6)
        }
    }

    private var historyTicks: [HistoryTick] {
        HistoryPreview.ticks(from: store.visibleItems).map { tick in
            var tick = tick
            if let item = store.items.first(where: { $0.id == tick.id }) {
                tick.branchCount = max(1, store.variants(for: item).count)
            }
            return tick
        }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.lastTurnDuration >= 1, !store.isBusy {
                        workedHeader(store.lastTurnDuration)
                    }
                    ForEach(displayRows) { row in
                        if isFirstRowAfterBranch(row) {
                            branchCutoverDivider
                        }
                        EquatableSection(value: rowRenderKey(row)) {
                            transcriptRow(row)
                        }
                        .equatable()
                        .id(row.id)
                        .opacity(isAfterBranchPoint(row) ? 0.34 : 1)
                    }
                    if store.isBusy {
                        WorkingRow(startedAt: store.turnStartedAt ?? Date())
                            .id("working")
                    }
                    ForEach(store.queuedMessages) { message in
                        queuedUserBubble(message)
                            .id("waiting-\(message.id.uuidString)")
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
            }
            .onAppear { requestFollowLatest(proxy) }
            .onChange(of: store.items.count) { _, _ in
                if store.items.last?.kind == .user {
                    followLatest = true
                }
                requestFollowLatest(proxy)
            }
            .onChange(of: store.transcriptRevision) { _, _ in
                requestFollowLatest(proxy)
            }
            .onChange(of: store.branchDraft?.sourceItemID) { _, sourceID in
                guard let sourceID else { return }
                followLatest = false
                OverlayPulse.shared.onNextFrame {
                    withAnimation(OverlayMotion.scroll) {
                        proxy.scrollTo(sourceID.uuidString, anchor: .center)
                    }
                }
            }
            .onChange(of: store.isBusy) { _, _ in
                requestFollowLatest(proxy)
            }
            .onChange(of: transcriptContentHeight) { _, _ in
                if TranscriptFollowPolicy.followsContentHeightChange(isBusy: store.isBusy) {
                    requestFollowLatest(proxy)
                }
            }
        }
    }

    private func isAfterBranchPoint(_ row: TranscriptRow) -> Bool {
        guard let sourceID = store.branchDraft?.sourceItemID,
              let sourceIndex = displayRows.firstIndex(where: { $0.contains(sourceID) }),
              let rowIndex = displayRows.firstIndex(where: { $0.id == row.id }) else { return false }
        return rowIndex > sourceIndex
    }

    private func isFirstRowAfterBranch(_ row: TranscriptRow) -> Bool {
        guard isAfterBranchPoint(row),
              let rowIndex = displayRows.firstIndex(where: { $0.id == row.id }) else { return false }
        return rowIndex == 0 || !isAfterBranchPoint(displayRows[rowIndex - 1])
    }

    private var branchCutoverDivider: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
            Text("Later messages stay on the original path")
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.vertical, 2)
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
        Button {
            store.openActiveWorkspaceStage()
        } label: {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show workspace session")
        .accessibilityLabel("Show workspace session")
    }

    private struct RunningSweepLabel: View {
        var body: some View {
            Text("running")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
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
        if store.branchDraft != nil || !store.draftClips.isEmpty || !store.draftImages.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let branch = store.branchDraft {
                        branchDraftChip(branch)
                    }
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

    private func branchDraftChip(_ branch: ConversationBranchDraft) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .semibold))
            Text("Branching from \(branch.title)")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Button {
                store.cancelBranchDraft()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Cancel branch edit")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
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

            if MessageDeliveryPolicy.composerSends(
                isBusy: store.isBusy,
                hasPayload: store.hasComposerPayload
            ) {
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
                .help("Add to waiting messages")
                .accessibilityLabel("Add message to waiting queue")
            } else if showComposerStop {
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

    private func rowRenderKey(_ row: TranscriptRow) -> RowRenderKey {
        let expansionKey: String
        switch row {
        case .message(let item):
            expansionKey = TranscriptExpansionPolicy.renderKey(
                containerExpanded: item.kind == .thought && expandedThoughts.contains(item.id),
                expandedChildIDs: []
            )
        case .tool(let item):
            expansionKey = TranscriptExpansionPolicy.renderKey(
                containerExpanded: expandedTools.contains(item.id),
                expandedChildIDs: []
            )
        case .collapsedTools(let id, let items):
            expansionKey = TranscriptExpansionPolicy.renderKey(
                containerExpanded: expandedToolGroups.contains(id),
                expandedChildIDs: items.filter { expandedTools.contains($0.id) }.map { $0.id.uuidString }
            )
        }
        switch row {
        case .message(let item), .tool(let item):
            return RowRenderKey(
                id: item.id.uuidString,
                kind: item.kind,
                text: item.text,
                toolStatus: item.toolStatus,
                toolKind: item.toolKind,
                toolInput: item.toolInput,
                toolOutput: item.toolOutput,
                imageNames: item.imageNames,
                workspaceStatus: item.workspaceStatus,
                workspaceSummary: item.workspaceSummary,
                live: store.streamingAssistantId == item.id
                    || store.streamingThoughtId == item.id
                    || store.workspacePaneStreamingAssistantId == item.id
                    || store.workspacePaneStreamingThoughtId == item.id,
                selected: store.workspaceStage?.cardId == item.id,
                expansionKey: expansionKey
            )
        case .collapsedTools(let id, let items):
            return RowRenderKey(
                id: id,
                kind: .tool,
                text: "\(items.count)",
                toolStatus: items.last?.toolStatus,
                toolKind: nil,
                toolInput: nil,
                toolOutput: nil,
                imageNames: nil,
                workspaceStatus: nil,
                workspaceSummary: nil,
                live: false,
                selected: false,
                expansionKey: expansionKey
            )
        }
    }

    private var showInputPlaceholder: Bool {
        store.draft.isEmpty && !ime.composing
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
    private func transcriptRow(_ row: TranscriptRow, interactive: Bool = true) -> some View {
        switch row {
        case .message(let item):
            switch item.kind {
            case .user:
                userBubble(item, interactive: interactive)
            case .assistant:
                assistantBubble(item, interactive: interactive)
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

    private func userBubble(_ item: ChatItem, interactive: Bool = true) -> some View {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = item.imageNames ?? []
        let variants = interactive ? store.variants(for: item) : []
        let currentVariant = variants.firstIndex(where: \.isCurrent)
        let showVariantSwitcher = interactive && ConversationBranchControlsPolicy.showsUserVariantSwitcher(
            variantCount: variants.count
        )
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
                        .textSelection(.enabled)
                }
                if item.deliveryState == .steering {
                    Text("Steering")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                if showVariantSwitcher, item.sourceEntryId != nil, item.deliveryState == nil,
                   let currentVariant {
                    HStack(spacing: 7) {
                        Button {
                            store.switchConversationBranch(to: variants[currentVariant - 1])
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(currentVariant == 0 || store.isBusy || store.childBusy || store.isSwitchingBranch)

                        Text("\(currentVariant + 1) / \(variants.count)")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.tertiary)

                        Button {
                            store.switchConversationBranch(to: variants[currentVariant + 1])
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(currentVariant + 1 >= variants.count || store.isBusy || store.childBusy || store.isSwitchingBranch)
                    }
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

    private func queuedUserBubble(_ message: QueuedUserMessage) -> some View {
        HStack {
            Spacer(minLength: 72)
            VStack(alignment: .trailing, spacing: 8) {
                if !message.imageNames.isEmpty {
                    VStack(alignment: .trailing, spacing: 8) {
                        ForEach(message.imageNames, id: \.self) { name in
                            userImageThumb(name)
                        }
                    }
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(OverlayMetrics.bodyFont)
                        .foregroundStyle(OverlayMetrics.ink)
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 10) {
                    Text("Waiting")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button {
                        store.steerQueuedMessage(message.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.up.right")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Steer now")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!MessageDeliveryPolicy.canSteer(.waiting, isBusy: store.isBusy))
                    .help("Send this message into the running turn")
                    .accessibilityLabel("Change waiting message to steering")
                }
            }
            .padding(.horizontal, message.imageNames.isEmpty ? 16 : 10)
            .padding(.vertical, message.imageNames.isEmpty ? 12 : 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
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

    private func assistantBubble(_ item: ChatItem, interactive: Bool = true) -> some View {
        let live = interactive
            ? store.isBusy && store.streamingAssistantId == item.id
            : store.childBusy && store.workspacePaneStreamingAssistantId == item.id
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let showBranchControl = interactive && ConversationBranchControlsPolicy.showsAssistantBranchAction(
            hasSourceEntry: item.sourceEntryId != nil,
            isStreaming: live
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                MessageBody(text: item.text, streaming: live)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if live {
                    StreamingCaret()
                }
            }
            if !live, !text.isEmpty {
                HStack(alignment: .center, spacing: 0) {
                    AssistantCopyButton(text: text)
                    if showBranchControl {
                        AssistantActionButton(
                            symbol: "arrow.triangle.branch",
                            help: "Branch from here",
                            accessibilityLabel: "Branch from here"
                        ) {
                            store.beginBranch(from: item)
                        }
                        .disabled(store.isBusy || store.childBusy || store.isSwitchingBranch || item.sourceBranchable == false)
                    }
                }
                .fixedSize(horizontal: true, vertical: true)
            }
        }
        .contextMenu {
            if interactive, item.sourceEntryId != nil, item.sourceBranchable != false {
                Button("Branch from here") { store.beginBranch(from: item) }
                    .disabled(store.isBusy || store.childBusy || store.isSwitchingBranch)
            }
        }
        .accessibilityAction(named: "Branch from here") {
            if interactive {
                store.beginBranch(from: item)
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
        let live = (store.isBusy && store.streamingThoughtId == item.id)
            || (store.childBusy && store.workspacePaneStreamingThoughtId == item.id)
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
        let live = status == "running" || status == "waiting"
        let selected = store.workspaceStage?.cardId == item.id
        let goal = item.workspaceGoal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = item.workspaceSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let question = item.workspaceQuestion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body: String = {
            if status == "waiting", !question.isEmpty { return question }
            if !summary.isEmpty { return workspacePreview(summary) }
            return ""
        }()
        return HStack(alignment: .top, spacing: 8) {
            Button {
                store.toggleWorkspaceStage(from: item)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .semibold))
                        Text(item.workspaceName ?? item.text)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if status == "running" {
                            RunningSweepLabel()
                        } else {
                            Text(status)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    if !goal.isEmpty {
                        Text(goal)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !body.isEmpty {
                        Text(body)
                            .font(.system(size: 12.5))
                            .foregroundStyle(status == "waiting" ? OverlayMetrics.ink.opacity(0.82) : .secondary)
                            .lineLimit(status == "running" ? 1 : 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show workspace session")
            .accessibilityLabel("Workspace run \(item.workspaceName ?? item.text), \(status)")
            .accessibilityHint("Shows the workspace session")
            if live {
                Button {
                    store.cancelWorkspaceRun()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Stop workspace run")
                .accessibilityLabel("Stop workspace run")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.08 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    selected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                    lineWidth: selected ? 1.5 : 1
                )
        )
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

    var body: some View {
        AssistantActionButton(
            symbol: copied ? "checkmark" : "square.on.square",
            help: "Copy this reply",
            accessibilityLabel: "Copy reply",
            active: copied,
            action: copy
        )
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

private struct AssistantActionButton: View {
    var symbol: String
    var help: String
    var accessibilityLabel: String
    var active = false
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active || hovered ? OverlayMetrics.ink.opacity(0.72) : Color.secondary.opacity(0.78))
                .frame(width: 14, height: 14, alignment: .center)
                .frame(width: 28, height: 28, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .onHover { hovering in
            hovered = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
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

private struct RowRenderKey: Equatable {
    var id: String
    var kind: ChatItem.Kind
    var text: String
    var toolStatus: String?
    var toolKind: String?
    var toolInput: String?
    var toolOutput: String?
    var imageNames: [String]?
    var workspaceStatus: String?
    var workspaceSummary: String?
    var live: Bool
    var selected: Bool
    var expansionKey: String
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ComposerDragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ComposerDragView: NSView {
    override var isOpaque: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private struct EquatableSection<Value: Equatable, Content: View>: View, Equatable {
    let value: Value
    let content: Content

    init(value: Value, @ViewBuilder content: () -> Content) {
        self.value = value
        self.content = content()
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value
    }

    var body: some View {
        content
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

    func contains(_ itemID: UUID) -> Bool {
        switch self {
        case .message(let item), .tool(let item):
            item.id == itemID
        case .collapsedTools(_, let items):
            items.contains { $0.id == itemID }
        }
    }
}

private extension WorkspaceTurnRow {
    init(_ item: ChatItem) {
        let kind: WorkspaceTurnRowKind
        switch item.kind {
        case .user:
            kind = .user
        case .assistant:
            kind = .assistant
        case .thought:
            kind = .thought
        case .tool:
            kind = .tool
        case .system, .workspaceRun:
            kind = .other
        }
        self.init(
            id: item.id.uuidString,
            sourceEntryId: item.sourceEntryId,
            kind: kind
        )
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
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary.opacity(0.35 + Double(index) * 0.18))
                    .frame(width: 5, height: 5)
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
        if let textView = window.firstResponder as? NSTextView, textView.isEditable {
            return textView.hasMarkedText()
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
        LayerPulsingCaret(width: 1.5, height: 16, duration: 0.53)
            .frame(width: 1.5, height: 16)
            .fixedSize()
    }
}

private struct StreamingCaret: View {
    var body: some View {
        LayerPulsingCaret(width: 1.6, height: 14, duration: 0.48)
            .frame(width: 1.6, height: 14)
            .fixedSize()
            .offset(y: 1)
    }
}

private struct LayerPulsingCaret: NSViewRepresentable {
    var width: CGFloat
    var height: CGFloat
    var duration: CFTimeInterval

    func makeNSView(context: Context) -> PulsingCaretNSView {
        PulsingCaretNSView(width: width, height: height, duration: duration)
    }

    func updateNSView(_ view: PulsingCaretNSView, context: Context) {
        view.configure(width: width, height: height, duration: duration)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PulsingCaretNSView, context: Context) -> CGSize {
        CGSize(width: width, height: height)
    }
}

private final class PulsingCaretNSView: NSView {
    private var caretWidth: CGFloat
    private var caretHeight: CGFloat
    private var duration: CFTimeInterval

    init(width: CGFloat, height: CGFloat, duration: CFTimeInterval) {
        caretWidth = width
        caretHeight = height
        self.duration = duration
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        configure(width: width, height: height, duration: duration)
    }

    required init?(coder: NSCoder) { nil }

    func configure(width: CGFloat, height: CGFloat, duration: CFTimeInterval) {
        caretWidth = width
        caretHeight = height
        layer?.backgroundColor = NSColor.labelColor.cgColor
        layer?.cornerRadius = width / 2
        layer?.opacity = 0.9
        invalidateIntrinsicContentSize()
        if self.duration != duration || layer?.animation(forKey: "bubble-pulse") == nil {
            self.duration = duration
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.12
            pulse.toValue = 0.9
            pulse.duration = duration
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            layer?.add(pulse, forKey: "bubble-pulse")
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: caretWidth, height: caretHeight)
    }
}

struct OverlayLayoutKey: PreferenceKey {
    static var defaultValue = OverlayLayout(
        totalHeight: 0,
        transcriptHeight: 0,
        pickerHeight: 0,
        commandPaletteHeight: 0,
        transcriptWidth: OverlayMetrics.transcriptWidthDefault,
        composerHeight: OverlayMetrics.minHeight,
        previewWidth: 0,
        chromeVisible: false
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
