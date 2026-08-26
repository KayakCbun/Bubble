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
        .id(sessions.state.selectedID)
        .overlay(alignment: .topLeading) {
            if sessions.showsTabs {
                VStack(alignment: .trailing, spacing: SessionTabLayoutMetrics.bubble.spacing) {
                    ForEach(sessions.tabs) { tab in
                        SessionTabButton(
                            tab: tab,
                            selected: tab.id == sessions.presentedSelectedID,
                            select: { sessions.select(tab.id) }
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
    }
}

private struct SessionTabButton: View {
    let tab: SessionTabState
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            if hovering {
                Text("\(tab.ordinal)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(selected ? Color.primary : Color.secondary)
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
            .fill(selected ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: SessionTabLayoutMetrics.bubble.cornerRadius,
                    bottomLeadingRadius: SessionTabLayoutMetrics.bubble.cornerRadius,
                    bottomTrailingRadius: 3,
                    topTrailingRadius: 3,
                    style: .continuous
                )
                .strokeBorder(Color.primary.opacity(selected ? 0.18 : 0.09), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
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
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .animation(OverlayMotion.quick, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session \(tab.ordinal)\(selected ? ", selected" : "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
