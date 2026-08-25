import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct PierreFileIconCheck {
    static func main() {
        expect(
            PierreFileIconCatalog.resolution(for: "src/Button.tsx").token == "react",
            "tsx files use the Pierre react token"
        )
        expect(
            PierreFileIconCatalog.resolution(for: "vite.config.ts").token == "vite",
            "vite config uses the filename token"
        )
        expect(
            PierreFileIconCatalog.resolution(for: "Dockerfile").token == "docker",
            "Dockerfile maps to docker"
        )
        expect(
            PierreFileIconCatalog.resolution(for: "foo.swift").token == "swift",
            "swift sources use the swift token"
        )
        expect(
            PierreFileIconCatalog.resolution(for: "notes.md").token == "markdown",
            "markdown files use the markdown token"
        )
        expect(
            PierreFileIconCatalog.resolution(for: "AGENTS.md").symbolID == "t3-file-icon-agents",
            "AGENTS.md uses the T3 extra glyph"
        )
        expect(
            PierreFileIconCatalog.resolution(for: "package.json").symbolID == "t3-file-icon-package-json",
            "package.json uses the T3 extra glyph"
        )
        expect(
            PierreFileIconCatalog.resolution(for: "artifact.unknown-ext").token == "default",
            "unknown types fall back to default"
        )
        expect(
            PierreFileIconCatalog.spriteXML.contains("file-tree-builtin-swift"),
            "complete sprite includes the swift glyph"
        )
        expect(
            !PierreFileIconCatalog.resolution(for: "package.json").tints,
            "T3 extras keep their baked fills"
        )
        print("PASS: pierre file icons")
    }
}
