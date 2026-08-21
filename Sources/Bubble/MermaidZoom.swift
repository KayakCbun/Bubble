import AppKit
import SwiftUI
import BeautifulMermaid

final class MermaidZoomController: NSObject, NSWindowDelegate {
    static let shared = MermaidZoomController()

    private var panel: NSPanel?
    private var localKeys: Any?

    var isVisible: Bool { panel?.isVisible == true }

    var isKey: Bool { panel?.isKeyWindow == true }

    func containsMouse() -> Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    func show(source: String, image: NSImage?) {
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(visible.width * 0.92, 1480).rounded()
        let height = min(visible.height * 0.88, 1020).rounded()
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
        let root = MermaidZoomView(source: source, image: image) { [weak self] in
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
        panel.title = "Diagram"
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

private struct MermaidZoomView: View {
    var source: String
    var image: NSImage?
    var onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hiRes: NSImage?
    @State private var webHeight: CGFloat = 520
    @State private var webFailed = false
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Diagram")
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
                    zoomBody
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(
                            width: (hiRes?.size.width ?? image?.size.width ?? 900) * scale,
                            height: bodyHeight * scale,
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
        .onAppear { renderHiRes() }
        .gesture(
            MagnificationGesture().onChanged { value in
                scale = min(4, max(0.6, value))
            }
        )
    }

    @ViewBuilder
    private var zoomBody: some View {
        if let shown = hiRes ?? image {
            Image(nsImage: shown)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else if !webFailed, MermaidResources.directory != nil {
            MermaidWKView(
                source: source,
                height: $webHeight,
                failed: $webFailed,
                interactive: true,
                maxHeight: 4200
            )
            .frame(minWidth: 720, minHeight: webHeight)
            .frame(height: webHeight)
        } else {
            Text(source)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var bodyHeight: CGFloat {
        if let shown = hiRes ?? image {
            return max(240, shown.size.height)
        }
        return max(240, webHeight)
    }

    private func renderHiRes() {
        let src = MessagePart.nativeMermaidSource(source)
        let dark = colorScheme == .dark
        DispatchQueue.global(qos: .userInitiated).async {
            var theme = dark ? DiagramTheme.zincDark : DiagramTheme.zincLight
            theme.transparent = true
            let rendered = try? MermaidRenderer.renderImage(source: src, theme: theme, scale: 3.0)
            DispatchQueue.main.async {
                if let rendered {
                    hiRes = MermaidImageFix.upright(rendered)
                }
            }
        }
    }
}
