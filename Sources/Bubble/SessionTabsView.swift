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
                    ForEach(Array(sessions.tabs.enumerated()), id: \.element.id) { index, tab in
                        SessionTabButton(
                            tab: tab,
                            selected: tab.id == sessions.presentedSelectedID,
                            stackIndex: index,
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

private enum SessionTabChrome {
    static let joinRadius: CGFloat = 5
}

private struct SessionTabButton: View {
    let tab: SessionTabState
    let selected: Bool
    let stackIndex: Int
    let preview: String
    let select: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var metrics: SessionTabLayoutMetrics { .bubble }

    private var fill: Color {
        if selected {
            return colorScheme == .dark
                ? Color(red: 0.16, green: 0.16, blue: 0.17)
                : .white
        }
        if colorScheme == .dark {
            return Color(white: hovering ? 0.26 : 0.22)
        }
        return Color(white: hovering ? 0.90 : 0.86)
    }

    private var tabShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: metrics.cornerRadius,
            bottomLeadingRadius: metrics.cornerRadius,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    var body: some View {
        Button(action: select) {
            Text("\(tab.ordinal)")
                .font(.system(size: 11, weight: selected ? .semibold : .medium, design: .rounded))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.48))
        .frame(
            width: selected ? metrics.expandedWidth : metrics.collapsedWidth,
            height: metrics.height
        )
        .background(alignment: .leading) { folderFace }
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
            width: metrics.expandedWidth,
            height: metrics.height,
            alignment: .trailing
        )
        .contentShape(Rectangle())
        .overlay(alignment: .topLeading) {
            if hovering {
                SessionTabPreviewCard(
                    ordinal: tab.ordinal,
                    preview: preview,
                    selected: selected
                )
                .offset(x: metrics.expandedWidth + 8, y: -4)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .leading)))
                .allowsHitTesting(false)
            }
        }
        .zIndex(hovering ? 40 : (selected ? 20 : Double(stackIndex + 1)))
        .animation(OverlayMotion.quick, value: hovering)
        .animation(OverlayMotion.quick, value: selected)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session \(tab.ordinal)\(selected ? ", selected" : "")")
        .accessibilityValue(preview)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Select Session \(tab.ordinal)", select)
    }

    private var folderFace: some View {
        let join = selected ? SessionTabChrome.joinRadius : 0
        let tabWidth = selected ? metrics.expandedWidth : metrics.collapsedWidth
        return ZStack(alignment: .topLeading) {
            tabShape
                .fill(fill)
                .frame(width: tabWidth, height: metrics.height)

            if selected {
                Rectangle()
                    .fill(fill)
                    .frame(width: 4, height: metrics.height)
                    .offset(x: tabWidth - 1)

                InverseFolderCorner(corner: .topTrailing)
                    .fill(fill, style: FillStyle(eoFill: true))
                    .frame(width: join, height: join)
                    .clipped()
                    .offset(x: tabWidth)

                InverseFolderCorner(corner: .bottomTrailing)
                    .fill(fill, style: FillStyle(eoFill: true))
                    .frame(width: join, height: join)
                    .clipped()
                    .offset(x: tabWidth, y: metrics.height - join)
            }
        }
        .frame(width: tabWidth + join, height: metrics.height, alignment: .topLeading)
        .compositingGroup()
        .shadow(
            color: .black.opacity(colorScheme == .dark ? (selected ? 0.28 : 0.18) : (selected ? 0.08 : 0.06)),
            radius: selected ? 3 : 2,
            x: -1.5,
            y: 1
        )
    }
}

private struct InverseFolderCorner: Shape {
    enum Corner {
        case topTrailing
        case bottomTrailing
    }

    var corner: Corner

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height)
        let center: CGPoint
        switch corner {
        case .topTrailing:
            center = CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomTrailing:
            center = CGPoint(x: rect.minX, y: rect.minY)
        }
        var path = Path()
        path.addRect(rect)
        path.addEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        return path
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
