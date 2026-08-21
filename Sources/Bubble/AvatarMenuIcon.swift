import AppKit

extension Notification.Name {
    static let bubbleAvatarDidChange = Notification.Name("bubbleAvatarDidChange")
}

enum AvatarMenuIcon {
    static let pointSize: CGFloat = 22

    static func image(for file: String) -> NSImage {
        if let silhouette = load(file), let image = render(silhouette) {
            return image
        }
        return render(fallbackSilhouette()) ?? sparklesFallback()
    }

    private struct Shape {
        var type: String
        var width: CGFloat
        var height: CGFloat
        var roundness: CGFloat
        var x: CGFloat
        var y: CGFloat
        var rotation: CGFloat
    }

    private struct Eye {
        var width: CGFloat
        var height: CGFloat
        var x: CGFloat
        var y: CGFloat
        var angle: CGFloat
    }

    private struct Silhouette {
        var body: Shape
        var nodes: [Shape]
        var left: Eye
        var right: Eye
        var spacing: CGFloat
    }

    private static func load(_ file: String) -> Silhouette? {
        guard let dir = AvatarResources.directory else { return nil }
        let url = dir.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = json["body"] as? [String: Any],
              let primary = body["primary"] as? [String: Any] else {
            return nil
        }
        let expressions = json["expressions"] as? [String: Any]
        let neutral = expressions?["neutral"] as? [String: Any]
        let eyes = (neutral?["eyes"] as? [String: Any]) ?? [:]
        let left = (eyes["left"] as? [String: Any]) ?? [:]
        let right = (eyes["right"] as? [String: Any]) ?? [:]
        let nodes = (body["nodes"] as? [[String: Any]] ?? []).compactMap(parseNode)
        return Silhouette(
            body: parseShape(primary, x: 0, y: 0, rotation: 0),
            nodes: nodes,
            left: parseEye(left),
            right: parseEye(right),
            spacing: number(eyes["spacing"]) ?? 35
        )
    }

    private static func parseNode(_ node: [String: Any]) -> Shape? {
        guard let surface = node["surface"] as? [String: Any] else { return nil }
        let position = node["position"] as? [Any] ?? []
        let rotation = node["rotation"] as? [Any] ?? []
        return parseShape(
            surface,
            x: number(position[safe: 0]) ?? 0,
            y: number(position[safe: 1]) ?? 0,
            rotation: number(rotation[safe: 2]) ?? 0
        )
    }

    private static func parseShape(_ raw: [String: Any], x: CGFloat, y: CGFloat, rotation: CGFloat) -> Shape {
        Shape(
            type: (raw["type"] as? String) ?? "sphere",
            width: max(1, number(raw["width"]) ?? 240),
            height: max(1, number(raw["height"]) ?? 240),
            roundness: number(raw["roundness"]) ?? 1,
            x: x,
            y: y,
            rotation: rotation
        )
    }

    private static func parseEye(_ raw: [String: Any]) -> Eye {
        Eye(
            width: max(4, number(raw["width"]) ?? 20),
            height: max(4, number(raw["height"]) ?? 50),
            x: number(raw["x"]) ?? 0,
            y: number(raw["y"]) ?? -7,
            angle: number(raw["angle"]) ?? 0
        )
    }

    private static func fallbackSilhouette() -> Silhouette {
        Silhouette(
            body: Shape(type: "sphere", width: 240, height: 240, roundness: 1, x: 0, y: 0, rotation: 0),
            nodes: [],
            left: Eye(width: 20, height: 50, x: 0, y: -7, angle: 0),
            right: Eye(width: 20, height: 50, x: 0, y: -7, angle: 0),
            spacing: 35
        )
    }

    private static func render(_ silhouette: Silhouette) -> NSImage? {
        let pixels = 88
        let padding: CGFloat = 2
        var minX = silhouette.body.x - silhouette.body.width / 2
        var maxX = silhouette.body.x + silhouette.body.width / 2
        var minY = silhouette.body.y - silhouette.body.height / 2
        var maxY = silhouette.body.y + silhouette.body.height / 2
        for node in silhouette.nodes {
            minX = min(minX, node.x - node.width / 2)
            maxX = max(maxX, node.x + node.width / 2)
            minY = min(minY, node.y - node.height / 2)
            maxY = max(maxY, node.y + node.height / 2)
        }
        let bounds = CGSize(width: max(1, maxX - minX), height: max(1, maxY - minY))
        let available = CGFloat(pixels) - padding * 2
        let scale = min(available / bounds.width, available / bounds.height)
        let offsetX = -((minX + maxX) / 2)
        let offsetY = -((minY + maxY) / 2)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.translateBy(x: CGFloat(pixels) / 2, y: CGFloat(pixels) / 2)
        // Avatar space is Y-up. The bitmap becomes a CGImage with origin
        // at the top, so flip Y or the silhouette stands on its head.
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: offsetX, y: offsetY)

        ctx.setFillColor(NSColor.black.cgColor)
        addShape(silhouette.body, to: ctx)
        for node in silhouette.nodes {
            addShape(node, to: ctx)
        }
        ctx.fillPath()
        punchEyes(in: silhouette.body, to: ctx)

        guard let cgImage = ctx.makeImage() else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: pointSize, height: pointSize))
        image.isTemplate = true
        image.accessibilityDescription = "Bubble"
        return image
    }

    private static func addShape(_ shape: Shape, to ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: shape.x, y: shape.y)
        if shape.rotation != 0 {
            ctx.rotate(by: shape.rotation * .pi / 180)
        }
        let rect = CGRect(x: -shape.width / 2, y: -shape.height / 2, width: shape.width, height: shape.height)
        switch shape.type {
        case "cube", "cylinder":
            let radius = min(shape.width, shape.height) / 2 * min(1, max(0, shape.roundness))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        case "capsule":
            let radius = min(shape.width, shape.height) / 2
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        case "cone":
            addCone(rect, to: ctx)
        default:
            ctx.addEllipse(in: rect)
        }
        ctx.restoreGState()
    }

    private static func addCone(_ rect: CGRect, to ctx: CGContext) {
        let top = CGPoint(x: rect.midX, y: rect.maxY)
        let left = CGPoint(x: rect.minX, y: rect.minY)
        let right = CGPoint(x: rect.maxX, y: rect.minY)
        let radius = min(rect.width, rect.height) * 0.16
        let path = CGMutablePath()
        path.move(to: CGPoint(x: (top.x + right.x) / 2, y: (top.y + right.y) / 2))
        path.addArc(tangent1End: right, tangent2End: left, radius: radius)
        path.addArc(tangent1End: left, tangent2End: top, radius: radius)
        path.addArc(tangent1End: top, tangent2End: right, radius: radius)
        path.closeSubpath()
        ctx.addPath(path)
    }

    private static func punchEyes(in body: Shape, to ctx: CGContext) {
        let width = max(body.width * 0.13, 28)
        let height = max(body.height * 0.30, 56)
        let spacing = max(body.width * 0.28, 58)
        let centerY: CGFloat
        switch body.type {
        case "cone":
            centerY = body.y - body.height * 0.10
        case "capsule":
            centerY = body.y + body.height * 0.06
        default:
            centerY = body.y + body.height * 0.04
        }
        ctx.setBlendMode(.clear)
        ctx.setFillColor(NSColor.black.cgColor)
        for side: CGFloat in [-1, 1] {
            let rect = CGRect(
                x: body.x + side * spacing / 2 - width / 2,
                y: centerY - height / 2,
                width: width,
                height: height
            )
            ctx.fillEllipse(in: rect)
        }
    }

    private static func sparklesFallback() -> NSImage {
        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Bubble")
            ?? NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.isTemplate = true
        return image
    }

    private static func number(_ value: Any?) -> CGFloat? {
        if let n = value as? NSNumber { return CGFloat(truncating: n) }
        if let n = value as? Double { return CGFloat(n) }
        if let n = value as? Int { return CGFloat(n) }
        return nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
