import AppKit
import SwiftUI

struct PierreFileIcon: View {
    var path: String
    var size: CGFloat = 16

    var body: some View {
        if let image = PierreFileIconCatalog.nsImage(for: path, pointSize: size) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "doc")
                .font(.system(size: size * 0.78, weight: .medium))
                .foregroundStyle(Color(red: 0.52, green: 0.54, blue: 0.58))
                .frame(width: size, height: size)
        }
    }
}

extension PierreFileIconCatalog {
    private static let symbols: [String: (viewBox: String, inner: String)] = parseSymbols(spriteXML)
    private static var imageCache: [String: NSImage] = [:]
    private static let cacheLock = NSLock()

    static func nsImage(for path: String, pointSize: CGFloat) -> NSImage? {
        let resolved = resolution(for: path)
        let hex = resolved.tints ? lightColorHex(for: resolved.token) : "000000"
        let key = "\(resolved.symbolID)|\(hex)|\(Int(pointSize * 2))"
        cacheLock.lock()
        if let cached = imageCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        guard let image = render(resolution: resolved, pointSize: pointSize) else { return nil }
        cacheLock.lock()
        imageCache[key] = image
        cacheLock.unlock()
        return image
    }

    private static func render(resolution: Resolution, pointSize: CGFloat) -> NSImage? {
        guard let symbol = symbols[resolution.symbolID] else { return nil }
        let pixels = max(16, Int((pointSize * 2).rounded()))
        var svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(pixels)" height="\(pixels)" viewBox="\(symbol.viewBox)">
        """
        if resolution.tints {
            svg += "<g fill=\"#\(lightColorHex(for: resolution.token))\" style=\"color:#\(lightColorHex(for: resolution.token))\">"
            svg += symbol.inner.replacingOccurrences(of: "currentColor", with: "#\(lightColorHex(for: resolution.token))")
            svg += "</g>"
        } else {
            svg += symbol.inner
        }
        svg += "</svg>"
        guard let data = svg.data(using: .utf8), let image = NSImage(data: data) else {
            return nil
        }
        image.size = NSSize(width: pointSize, height: pointSize)
        return image
    }

    private static func parseSymbols(_ xml: String) -> [String: (viewBox: String, inner: String)] {
        var result: [String: (viewBox: String, inner: String)] = [:]
        let pattern = #"<symbol id="([^"]+)" viewBox="([^"]+)">([\s\S]*?)</symbol>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = xml as NSString
        let range = NSRange(location: 0, length: ns.length)
        regex.enumerateMatches(in: xml, range: range) { match, _, _ in
            guard let match,
                  match.numberOfRanges == 4,
                  let idRange = Range(match.range(at: 1), in: xml),
                  let boxRange = Range(match.range(at: 2), in: xml),
                  let innerRange = Range(match.range(at: 3), in: xml) else { return }
            result[String(xml[idRange])] = (String(xml[boxRange]), String(xml[innerRange]))
        }
        return result
    }
}
