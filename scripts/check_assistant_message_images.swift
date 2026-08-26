import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("assistant message image check failed: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum AssistantMessageImageCheck {
    static func main() {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let content: [String: Any] = [
            "type": "image",
            "mimeType": "image/png",
            "data": png,
        ]

        let chunk = AssistantMessageContent.parse(content)
        require(chunk?.image?.mimeType == "image/png", "ACP image MIME type is preserved")
        require(chunk?.image?.data == Data(base64Encoded: png), "ACP image payload is decoded")
        require(chunk?.text == nil, "an image chunk does not invent assistant text")

        let text = AssistantMessageContent.parse(["type": "text", "text": "Rendered answer"])
        require(text?.text == "Rendered answer", "ACP assistant text keeps streaming through the same seam")
        require(text?.image == nil, "a text chunk does not invent an image")

        require(
            AssistantMessagePresentation.hasContent(text: "", imageNames: ["answer.png"]),
            "an image-only assistant message remains visible and persistable"
        )
        require(
            !AssistantMessagePresentation.hasContent(text: "  \n", imageNames: []),
            "a genuinely empty assistant message remains hidden"
        )

        let toolImages = AssistantMessageContent.images(in: [
            "content": [
                ["type": "text", "text": "Read image file"],
                ["type": "image", "mimeType": "image/png", "data": png],
            ],
        ])
        require(toolImages.count == 1, "Pi tool-result images are discovered from structured output")
        require(toolImages.first?.data == Data(base64Encoded: png), "tool-result image data is decoded")
        require(
            AssistantMessageContent.texts(in: ["content": [["type": "text", "text": "Read image file"], content]]) == ["Read image file"],
            "tool-result text remains visible beside extracted images"
        )

        let ordered = AssistantMessagePresentation.blocks(
            text: "beforeafter",
            imageNames: ["generated.png"],
            placements: [AssistantImagePlacement(name: "generated.png", textOffset: 6)]
        )
        require(
            ordered == [.text("before"), .image("generated.png"), .text("after")],
            "interleaved assistant text and images preserve content-block order"
        )
    }
}
