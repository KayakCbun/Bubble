import AppKit
import BubbleSessions
import SwiftUI

struct SessionOverlayView: View {
    @Bindable var sessions: SessionTabsStore
    var onToggleWidth: () -> Void

    var body: some View {
        OverlayView(
            store: sessions.activeStore,
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
    let select: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var fill: Color {
        if selected {
            return colorScheme == .dark
                ? Color(red: 0.16, green: 0.16, blue: 0.17)
                : .white
        }
        if colorScheme == .dark {
            return Color(white: hovering ? 0.22 : 0.19)
        }
        return Color(white: hovering ? 0.94 : 0.89)
    }

    private var tabShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: SessionTabLayoutMetrics.bubble.cornerRadius,
            bottomLeadingRadius: SessionTabLayoutMetrics.bubble.cornerRadius,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    private var backingFill: Color {
        colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.80)
    }

    var body: some View {
        Button(action: select) {
            Text("\(tab.ordinal)")
                .font(.system(size: 12, weight: selected ? .bold : .semibold, design: .rounded))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(
                width: selected
                    ? SessionTabLayoutMetrics.bubble.expandedWidth
                    : SessionTabLayoutMetrics.bubble.collapsedWidth,
                height: SessionTabLayoutMetrics.bubble.height
            )
            .background {
                ZStack {
                    // A slightly displaced sheet edge remains visible below
                    // each tab. With zero strip spacing these edges overlap
                    // into one vertical stack instead of separate buttons.
                    tabShape
                        .fill(backingFill)
                        .offset(x: 2, y: 3)

                    tabShape
                        .fill(fill)
                        .overlay {
                            tabShape
                                .strokeBorder(
                                    selected
                                        ? Color.primary.opacity(0.24)
                                        : Color.primary.opacity(0.10),
                                    lineWidth: selected ? 1.25 : 0.75
                                )
                        }
                }
                .shadow(
                    color: .black.opacity(selected ? 0.14 : 0.09),
                    radius: selected ? 5 : 2,
                    x: -1,
                    y: 2
                )
            }
            .overlay(alignment: .trailing) {
                if selected {
                    // Cover both the tab's trailing stroke and the transcript
                    // card's leading hairline so the selected tab reads as
                    // one continuous folder surface with the conversation.
                    Rectangle()
                        .fill(fill)
                        .frame(width: 7, height: SessionTabLayoutMetrics.bubble.height - 2)
                        .offset(x: 3)
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
            if hovering {
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
