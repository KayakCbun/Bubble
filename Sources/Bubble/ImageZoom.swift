import AppKit
import SwiftUI

final class ImageZoomController: NSObject, NSWindowDelegate {
    static let shared = ImageZoomController()

    private var panel: NSPanel?
    private var localKeys: Any?

    var isVisible: Bool { panel?.isVisible == true }

    func containsMouse() -> Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    func show(_ image: NSImage) {
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(visible.width * 0.88, 1280).rounded()
        let height = min(visible.height * 0.88, 960).rounded()
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
        let root = ImageZoomView(image: image) { [weak self] in
            self?.close()
        }
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
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
        panel.title = "Image"
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
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

private struct ImageZoomView: View {
    var image: NSImage
    var onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Image")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button {
                        scale = 1
                    } label: {
                        Image(systemName: "1.magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Actual size")
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Close")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(
                            width: max(240, image.size.width) * scale,
                            height: max(240, image.size.height) * scale,
                            alignment: .topLeading
                        )
                        .padding(20)
                }
                .background(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.03))
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(18)
        }
        .gesture(
            MagnificationGesture().onChanged { value in
                scale = min(6, max(0.4, value))
            }
        )
    }
}
