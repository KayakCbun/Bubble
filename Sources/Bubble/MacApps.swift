import AppKit
import Foundation

struct MacApp: Identifiable, Equatable {
    var name: String
    var url: URL
    var bundleId: String
    var running: Bool

    var id: String { bundleId.isEmpty ? url.path : bundleId }
}

enum MacApps {
    private static let lock = NSLock()
    private static var cached: [MacApp] = []
    private static var icons: [String: NSImage] = [:]

    static func icon(for app: MacApp) -> NSImage {
        icon(forPath: app.url.path, cacheKey: app.id)
    }

    static func icon(forPath path: String, cacheKey: String? = nil) -> NSImage {
        let key = cacheKey ?? path
        lock.lock()
        if let cached = icons[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let raw = NSWorkspace.shared.icon(forFile: path)
        let icon = (raw.copy() as? NSImage) ?? raw
        icon.size = NSSize(width: 64, height: 64)
        lock.lock()
        icons[key] = icon
        lock.unlock()
        return icon
    }

    static func apps() -> [MacApp] {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    static func refresh() -> [MacApp] {
        let indexed = index()
        lock.lock()
        cached = indexed
        lock.unlock()
        return indexed
    }

    static func search(_ query: String, in apps: [MacApp]? = nil) -> [MacApp] {
        let list = apps ?? (self.apps().isEmpty ? refresh() : self.apps())
        return ranked(list, query: query)
    }

    static func resolve(_ query: String) -> MacApp? {
        let matches = search(query)
        guard let first = matches.first else { return nil }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        let q = query.lowercased()
        if first.name.lowercased() == q || first.bundleId.lowercased() == q {
            return first
        }
        if matches.count == 1 { return first }
        let tight = matches.filter {
            $0.name.lowercased().hasPrefix(q) || $0.bundleId.lowercased().hasPrefix(q)
        }
        return tight.count == 1 ? tight[0] : nil
    }

    static func launch(_ app: MacApp) -> String? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { _, error in
            if let error {
                OverlayLog.write("open app failed \(app.name): \(error.localizedDescription)")
            }
        }
        return nil
    }

    static func launchIntent(from text: String) -> MacApp? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/") else { return nil }
        let prefixes = [
            "请帮我打开", "请幫我打開", "帮我打开", "幫我打開",
            "请打开", "請打開", "麻烦打开", "麻煩打開",
            "打开应用", "打開應用", "打开一下", "打開一下",
            "打开下", "打開下", "启动", "啟動", "开启", "開啟", "打开", "打開",
            "please open ", "open the ", "launch ", "start ", "open ",
        ]
        let lowered = trimmed.lowercased()
        var rest: String?
        for prefix in prefixes {
            if trimmed.hasPrefix(prefix) {
                rest = String(trimmed.dropFirst(prefix.count))
                break
            }
            if lowered.hasPrefix(prefix.lowercased()) {
                rest = String(trimmed.dropFirst(prefix.count))
                break
            }
        }
        guard var rest else { return nil }
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "。.!！?"))
        if rest.hasSuffix("吧") || rest.hasSuffix("呀") || rest.hasSuffix("啊") {
            rest = String(rest.dropLast())
        }
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty, rest.count <= 40, !rest.contains(" ") || rest.split(separator: " ").count <= 3 else {
            return nil
        }
        return resolve(rest)
    }

    private static func ranked(_ apps: [MacApp], query: String) -> [MacApp] {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            let running = apps.filter(\.running)
            let rest = apps.filter { !$0.running }
            return Array((running + rest).prefix(40))
        }
        let scored: [(Int, MacApp)] = apps.compactMap { app in
            let name = app.name.lowercased()
            let bundle = app.bundleId.lowercased()
            let score: Int?
            if name == q || bundle == q { score = 0 }
            else if name.hasPrefix(q) { score = 1 }
            else if bundle.hasPrefix(q) { score = 2 }
            else if name.contains(q) { score = 3 }
            else if bundle.contains(q) { score = 4 }
            else { score = nil }
            guard let score else { return nil }
            return (app.running ? score : score + 10, app)
        }
        return scored.sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1.name.localizedCaseInsensitiveCompare(rhs.1.name) == .orderedAscending
        }.map(\.1)
    }

    private static func index() -> [MacApp] {
        let fm = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true),
            OverlayPaths.home.appendingPathComponent("Applications", isDirectory: true),
        ]
        var seen = Set<String>()
        var apps: [MacApp] = []
        for root in roots {
            collect(from: root, depth: 0, into: &apps, seen: &seen, fm: fm)
        }

        let runningIds = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        for index in apps.indices {
            if runningIds.contains(apps[index].bundleId) {
                apps[index].running = true
            }
        }

        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            guard let url = running.bundleURL else { continue }
            let bundleId = running.bundleIdentifier ?? url.path
            guard seen.insert(bundleId).inserted else { continue }
            let name = running.localizedName
                ?? fm.displayName(atPath: url.path)
                ?? url.deletingPathExtension().lastPathComponent
            apps.append(MacApp(name: name, url: url, bundleId: bundleId, running: true))
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func collect(
        from directory: URL,
        depth: Int,
        into apps: inout [MacApp],
        seen: inout Set<String>,
        fm: FileManager
    ) {
        guard depth <= 2 else { return }
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            if name.hasPrefix(".") { continue }
            let url = directory.appendingPathComponent(name)
            if name.hasSuffix(".app") {
                appendApp(url, into: &apps, seen: &seen, fm: fm)
                continue
            }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            collect(from: url, depth: depth + 1, into: &apps, seen: &seen, fm: fm)
        }
    }

    private static func appendApp(
        _ url: URL,
        into apps: inout [MacApp],
        seen: inout Set<String>,
        fm: FileManager
    ) {
        let bundle = Bundle(url: url)
        let bundleId = bundle?.bundleIdentifier ?? url.path
        guard seen.insert(bundleId).inserted else { return }
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? fm.displayName(atPath: url.path)
            ?? url.deletingPathExtension().lastPathComponent
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        apps.append(MacApp(name: trimmed, url: url, bundleId: bundleId, running: false))
    }
}
