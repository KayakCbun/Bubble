import AppKit
import SwiftUI

final class FileChangeDiffController: NSObject, NSWindowDelegate {
    static let shared = FileChangeDiffController()

    private var panel: NSPanel?
    private var localKeys: Any?

    var isVisible: Bool { panel?.isVisible == true }

    func containsMouse() -> Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    func show(_ summary: FileChangeSummary) {
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(visible.width * 0.72, 920).rounded()
        let height = min(visible.height * 0.78, 720).rounded()
        var frame = NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )
        frame.origin.x = max(visible.minX + 16, frame.origin.x)
        frame.origin.y = max(visible.minY + 16, frame.origin.y)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let root = FileChangeDiffView(summary: summary) { [weak self] in
            self?.close()
        }
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.white.cgColor
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installKeys()
    }

    func close() {
        removeKeys()
        panel?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Changed files"
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = true
        panel.backgroundColor = .white
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        return panel
    }

    private func installKeys() {
        removeKeys()
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.close()
                return nil
            }
            return event
        }
    }

    private func removeKeys() {
        if let localKeys {
            NSEvent.removeMonitor(localKeys)
            self.localKeys = nil
        }
    }
}

private struct FileChangeDiffView: View {
    var summary: FileChangeSummary
    var onClose: () -> Void
    @State private var selected: String?

    var body: some View {
        let current = summary.files.first(where: { $0.path == selected }) ?? summary.files.first
        VStack(spacing: 0) {
            HStack {
                Text("\(summary.files.count) changed file\(summary.files.count == 1 ? "" : "s")")
                    .font(OverlayMetrics.font(size: 13, weight: .semibold))
                if let additions = summary.additions, summary.hasLineStats {
                    Text("+\(additions)")
                        .foregroundStyle(Color(red: 0.18, green: 0.62, blue: 0.32))
                }
                if let deletions = summary.deletions, summary.hasLineStats {
                    Text("-\(deletions)")
                        .foregroundStyle(Color(red: 0.82, green: 0.22, blue: 0.25))
                }
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(summary.files) { file in
                            Button {
                                selected = file.path
                            } label: {
                                HStack {
                                    Text(file.fileName)
                                        .lineLimit(1)
                                    Spacer()
                                    if file.hasLineStats {
                                        if let additions = file.additions {
                                            Text("+\(additions)")
                                                .foregroundStyle(Color(red: 0.18, green: 0.62, blue: 0.32))
                                        }
                                        if let deletions = file.deletions {
                                            Text("-\(deletions)")
                                                .foregroundStyle(Color(red: 0.82, green: 0.22, blue: 0.25))
                                        }
                                    }
                                }
                                .font(OverlayMetrics.font(size: 12, weight: .regular))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(file.path == current?.path ? Color.primary.opacity(0.06) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
                .frame(minWidth: 220, idealWidth: 260)
                ScrollView {
                    Text(diffText(current))
                        .font(OverlayMetrics.font(size: 12, design: .monospaced))
                        .bubbleTextSelection()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        }
        .onAppear { selected = summary.files.first?.path }
    }

    private func diffText(_ file: FileChange?) -> String {
        guard let file else { return "No file selected." }
        if file.oldText != nil || file.newText != nil {
            return FileChangeSummaryPolicy.unifiedDiff(path: file.path, old: file.oldText, new: file.newText)
        }
        return file.path
    }
}
