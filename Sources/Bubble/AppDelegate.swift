import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let overlay = OverlayController()
    private var statusItem: NSStatusItem?
    private var avatarObserver: NSObjectProtocol?
    private var configObserver: NSObjectProtocol?
    private let modelMenu = NSMenu(title: "Model")
    private let thinkingMenu = NSMenu(title: "Thinking")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        OverlayEditCommands.installMainMenu()
        overlay.start()
        installStatusItem()
        OverlayLog.write("launched")
        if ProcessInfo.processInfo.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.overlay.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay.stop()
    }

    func applicationDidResignActive(_ notification: Notification) {
        overlay.hideIfFocusLost()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.imagePosition = .imageOnly
        applyStatusIcon(AvatarSelection.file, to: item)

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Toggle Overlay", action: #selector(toggleOverlay), keyEquivalent: "")
        menu.addItem(withTitle: "Enable Double-tap ⌘…", action: #selector(enableHotkey), keyEquivalent: "")
        menu.addItem(.separator())

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        let thinkingItem = NSMenuItem(title: "Thinking", action: nil, keyEquivalent: "")
        thinkingItem.submenu = thinkingMenu
        menu.addItem(thinkingItem)

        menu.addItem(withTitle: "Workspaces…", action: #selector(openWorkspaces), keyEquivalent: "")
        menu.addItem(withTitle: "Sign in with Pi…", action: #selector(signInWithPi), keyEquivalent: "")
        menu.addItem(withTitle: "Edit AGENTS.md", action: #selector(editAgents), keyEquivalent: "")
        menu.addItem(withTitle: "Attach Clipboard", action: #selector(attachClipboard), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Bubble Folder", action: #selector(openLogs), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        for menuItem in menu.items {
            menuItem.target = self
        }
        item.menu = menu
        rebuildConfigMenus()
        configObserver = NotificationCenter.default.addObserver(
            forName: .bubbleSessionConfigDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildConfigMenus()
        }
        statusItem = item
        avatarObserver = NotificationCenter.default.addObserver(
            forName: .bubbleAvatarDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let file = (note.object as? String) ?? AvatarSelection.file
            self?.applyStatusIcon(file, to: self?.statusItem)
        }
    }

    private func applyStatusIcon(_ file: String, to item: NSStatusItem?) {
        guard let button = item?.button else { return }
        let image = AvatarMenuIcon.image(for: file)
        image.isTemplate = true
        image.size = NSSize(width: AvatarMenuIcon.pointSize, height: AvatarMenuIcon.pointSize)
        button.image = image
        button.imageScaling = .scaleProportionallyUpOrDown
        button.toolTip = "Bubble"
    }

    @objc private func toggleOverlay() {
        overlay.toggle()
    }

    @objc private func enableHotkey() {
        overlay.promptAccessibility()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusItem?.menu || menu === modelMenu || menu === thinkingMenu {
            rebuildConfigMenus()
        }
    }

    private func rebuildConfigMenus() {
        let store = overlay.store
        let models = store.availableModels.isEmpty ? BubbleConfig.catalogModels() : store.availableModels
        modelMenu.removeAllItems()
        if models.isEmpty {
            let empty = NSMenuItem(title: "No models yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            modelMenu.addItem(empty)
        } else {
            for model in models {
                let item = NSMenuItem(
                    title: model.displayName,
                    action: #selector(selectModel(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = model.identity
                item.state = model.identity == store.currentModelId ? .on : .off
                modelMenu.addItem(item)
            }
        }

        thinkingMenu.removeAllItems()
        for level in store.thinkingLevels {
            let item = NSMenuItem(title: level, action: #selector(selectThinking(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = level
            item.state = level == store.currentThinking ? .on : .off
            thinkingMenu.addItem(item)
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let identity = sender.representedObject as? String else { return }
        overlay.store.applyModel(identity, announce: true)
        overlay.show()
    }

    @objc private func selectThinking(_ sender: NSMenuItem) {
        guard let level = sender.representedObject as? String else { return }
        overlay.store.applyThinking(level, announce: true)
        overlay.show()
    }

    @objc private func openWorkspaces() {
        overlay.show()
        overlay.store.openMountsPalette()
    }

    @objc private func signInWithPi() {
        overlay.show()
        overlay.store.presentLogin()
    }

    @objc private func editAgents() {
        overlay.store.openAgentsFile()
    }

    @objc private func attachClipboard() {
        overlay.show()
        overlay.store.attachClipboard()
    }

    @objc private func openLogs() {
        OverlayPaths.bootstrap()
        NSWorkspace.shared.open(OverlayPaths.root)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
