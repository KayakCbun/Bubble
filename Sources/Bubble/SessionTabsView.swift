import AppKit
import BubbleSessions
import SwiftUI

struct SessionOverlayView: View {
    @Bindable var sessions: SessionTabsStore
    var onEscape: () -> Void
    var onToggleWidth: () -> Void

    var body: some View {
        OverlayView(
            store: sessions.activeStore,
            onEscape: onEscape,
            onToggleWidth: onToggleWidth,
            sessionTabCount: sessions.showsTabs ? sessions.tabs.count : 0,
            sessionSwitchLoading: sessions.isSwitchingSession
        )
        .overlay(alignment: .topLeading) {
            if sessions.showsTabs {
                VStack(alignment: .trailing, spacing: SessionTabLayoutMetrics.bubble.spacing) {
                    ForEach(sessions.tabs) { tab in
                        SessionTabButton(
                            tab: tab,
                            selected: tab.id == sessions.presentedSelectedID,
                            preview: sessions.preview(for: tab.id),
                            closeEnabled: !sessions.isSwitchingSession,
                            select: { sessions.select(tab.id) },
                            close: { stopIfBusy in
                                sessions.closeSideSession(tab.id, stopIfBusy: stopIfBusy)
                            }
                        )
                    }
                }
                .frame(width: SessionTabLayoutMetrics.bubble.expandedWidth, alignment: .trailing)
                .padding(.top, OverlayMetrics.shadowInset + SessionTabLayoutMetrics.bubble.topOffset)
                .padding(
                    .leading,
                    OverlayMetrics.shadowInset - SessionTabLayoutMetrics.bubble.expandedWidth
                )
                .transition(.opacity)
            }
        }
        .animation(OverlayMotion.quick, value: sessions.showsTabs)
        .onAppear {
            sessions.startSessionSwitchDiagnosticIfNeeded()
        }
        .onChange(of: sessions.state.selectedID) { _, selectedID in
            OverlayPulse.shared.onNextFrame {
                sessions.selectedLayoutDidApply(selectedID)
            }
        }
    }
}

private struct SessionTabButton: View {
    let tab: SessionTabState
    let selected: Bool
    let preview: String
    let closeEnabled: Bool
    let select: () -> Void
    let close: (_ stopIfBusy: Bool) -> Void
    @State private var hovering = false
    @State private var hoveringClose = false
    @State private var showingCloseConfirmation = false

    var body: some View {
        HStack(spacing: 3) {
            Button(action: select) {
                Text("\(tab.ordinal)")
                    .font(.system(size: 11, weight: selected ? .bold : .semibold, design: .rounded))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if (hovering || showingCloseConfirmation), tab.ordinal != 1, closeEnabled {
                Button(action: requestClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    tab.isBusy
                        ? "Stop and close Session \(tab.ordinal)"
                        : "Close Session \(tab.ordinal)"
                )
                .foregroundStyle(Color.secondary.opacity(hoveringClose ? 0.95 : 0.64))
                .onHover { hoveringClose = $0 }
                .help(tab.isBusy ? "Stop and close Session \(tab.ordinal)" : "Close Session \(tab.ordinal)")
                .popover(isPresented: $showingCloseConfirmation, arrowEdge: .leading) {
                    SessionTabCloseConfirmation(
                        ordinal: tab.ordinal,
                        cancel: { showingCloseConfirmation = false },
                        confirm: {
                            showingCloseConfirmation = false
                            close(true)
                        }
                    )
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .frame(
                width: hovering
                    ? SessionTabLayoutMetrics.bubble.expandedWidth
                    : SessionTabLayoutMetrics.bubble.collapsedWidth,
                height: SessionTabLayoutMetrics.bubble.height
            )
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: SessionTabLayoutMetrics.bubble.cornerRadius,
                    bottomLeadingRadius: SessionTabLayoutMetrics.bubble.cornerRadius,
                    bottomTrailingRadius: 3,
                    topTrailingRadius: 3,
                    style: .continuous
                )
                .fill(
                    selected
                        ? Color(nsColor: .controlBackgroundColor)
                        : Color(nsColor: hovering ? .controlBackgroundColor : .windowBackgroundColor)
                )
                .overlay {
                    UnevenRoundedRectangle(
                        topLeadingRadius: SessionTabLayoutMetrics.bubble.cornerRadius,
                        bottomLeadingRadius: SessionTabLayoutMetrics.bubble.cornerRadius,
                        bottomTrailingRadius: 3,
                        topTrailingRadius: 3,
                        style: .continuous
                    )
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.58) : Color.primary.opacity(0.09),
                        lineWidth: selected ? 1.5 : 1
                    )
                }
                .shadow(color: .black.opacity(selected ? 0.13 : 0.08), radius: 4, y: 1)
            }
            .overlay(alignment: .trailing) {
                if selected {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 16)
                        .offset(x: 1)
                }
            }
            .overlay(alignment: .topLeading) {
                if tab.hasUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .offset(x: 3, y: 3)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if tab.isBusy {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.8))
                        .frame(width: 8, height: 2)
                        .offset(x: 3, y: -3)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovering in
                hovering = isHovering
                if isHovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }

        .frame(
            width: SessionTabLayoutMetrics.bubble.expandedWidth,
            height: SessionTabLayoutMetrics.bubble.height,
            alignment: .trailing
        )
        .overlay(alignment: .topLeading) {
            if hovering, !hoveringClose, !showingCloseConfirmation {
                SessionTabPreviewCard(
                    ordinal: tab.ordinal,
                    preview: preview,
                    selected: selected
                )
                .offset(x: SessionTabLayoutMetrics.bubble.expandedWidth + 8, y: -4)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .leading)))
                .allowsHitTesting(false)
            }
        }
        .zIndex(hovering ? 20 : (selected ? 2 : 1))
        .animation(OverlayMotion.quick, value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session \(tab.ordinal)\(selected ? ", selected" : "")")
        .accessibilityValue(preview)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Select Session \(tab.ordinal)", select)
        .accessibilityActions {
            if tab.ordinal != 1, closeEnabled {
                Button("Close Session \(tab.ordinal)", action: requestClose)
            }
        }
    }

    private func requestClose() {
        if tab.isBusy {
            showingCloseConfirmation = true
        } else {
            close(false)
        }
    }
}

private struct SessionTabCloseConfirmation: View {
    let ordinal: Int
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session \(ordinal) is still running")
                .font(.system(size: 13, weight: .semibold))
            Text("Stop its current work and close this side session?")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Stop & Close", role: .destructive, action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 270)
    }
}

private struct SessionTabPreviewCard: View {
    let ordinal: Int
    let preview: String
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(selected ? Color.accentColor : Color.secondary.opacity(0.55))
                    .frame(width: 6, height: 6)
                Text("Session \(ordinal)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(preview)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: 280, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.16) : Color.white)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}
