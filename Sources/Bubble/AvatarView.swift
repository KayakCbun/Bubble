import AppKit
import SwiftUI
import WebKit

enum AvatarSelection {
    static let defaultFile = "bubble.avatar.json"

    static var file: String {
        get {
            if let stored = (try? String(contentsOf: OverlayPaths.avatarFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !stored.isEmpty {
                return stored
            }
            return UserDefaults.standard.string(forKey: "bubble.avatar.file") ?? defaultFile
        }
        set {
            OverlayPaths.bootstrap()
            try? newValue.write(to: OverlayPaths.avatarFile, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(newValue, forKey: "bubble.avatar.file")
            NotificationCenter.default.post(name: .bubbleAvatarDidChange, object: newValue)
        }
    }
}

struct FxAvatarView: NSViewRepresentable {
    var file: String
    var animation: String
    var onTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "togglePicker")
        let webView = AvatarWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        if let prefs = webView.value(forKeyPath: "configuration.preferences") as? NSObject {
            prefs.setValue(true, forKey: "allowFileAccessFromFileURLs")
        }
        context.coordinator.webView = webView
        context.coordinator.pendingAnimation = animation
        context.coordinator.pendingFile = file
        if let dir = AvatarResources.directory {
            let html = dir.appendingPathComponent("index.html")
            webView.loadFileURL(html, allowingReadAccessTo: dir)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.set(file: file, animation: animation)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "togglePicker")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onTap: () -> Void
        weak var webView: WKWebView?
        var ready = false
        var pendingFile = AvatarSelection.defaultFile
        var pendingAnimation = "idle"

        init(onTap: @escaping () -> Void) {
            self.onTap = onTap
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            inject()
        }

        func set(file: String, animation: String) {
            pendingFile = file
            pendingAnimation = animation
            if ready {
                inject()
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "togglePicker" {
                DispatchQueue.main.async { self.onTap() }
            }
        }

        private var appliedFile = ""
        private var appliedAnimation = ""

        private func inject() {
            guard pendingFile != appliedFile || pendingAnimation != appliedAnimation else { return }
            appliedFile = pendingFile
            appliedAnimation = pendingAnimation
            let file = pendingFile.replacingOccurrences(of: "'", with: "\\'")
            let animation = pendingAnimation.replacingOccurrences(of: "'", with: "\\'")
            webView?.evaluateJavaScript("window.fxAvatarLoad && window.fxAvatarLoad('\(file)', '\(animation)')")
        }
    }
}

struct AvatarPickerView: NSViewRepresentable {
    var selectedFile: String
    var onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "selectAvatar")
        let webView = AvatarWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        if let prefs = webView.value(forKeyPath: "configuration.preferences") as? NSObject {
            prefs.setValue(true, forKey: "allowFileAccessFromFileURLs")
        }
        if let dir = AvatarResources.directory {
            var html = dir.appendingPathComponent("picker.html")
            if var components = URLComponents(url: html, resolvingAgainstBaseURL: false) {
                components.queryItems = [URLQueryItem(name: "selected", value: selectedFile)]
                if let url = components.url {
                    html = url
                }
            }
            webView.loadFileURL(
                dir.appendingPathComponent("picker.html"),
                allowingReadAccessTo: dir
            )
            // selected is also read from query; inject after load via coordinator
            context.coordinator.selectedFile = selectedFile
            webView.navigationDelegate = context.coordinator
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSelect = onSelect
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "selectAvatar")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onSelect: (String) -> Void
        var selectedFile: String = AvatarSelection.defaultFile

        init(onSelect: @escaping (String) -> Void) {
            self.onSelect = onSelect
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "selectAvatar" else { return }
            let file: String
            if let body = message.body as? [String: Any], let value = body["file"] as? String {
                file = value
            } else if let value = message.body as? String {
                file = value
            } else {
                return
            }
            DispatchQueue.main.async { self.onSelect(file) }
        }
    }
}

private final class AvatarWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
}

enum AvatarResources {
    static var directory: URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let candidates = [
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Avatar")?
                .deletingLastPathComponent(),
            exe.deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/Avatar"),
            exe.deletingLastPathComponent().appendingPathComponent("Avatar"),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path)
        }
    }
}
