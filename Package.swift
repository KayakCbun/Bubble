// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Bubble",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "Bubble", targets: ["Bubble"]),
        .library(name: "BubbleMounts", targets: ["BubbleMounts"]),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
        .package(url: "https://github.com/colinc86/LaTeXSwiftUI", from: "1.5.0"),
        // LaTeXSwiftUI 1.x allows newer SwiftDraw releases whose SwiftUI
        // preview/environment macros are unavailable in Bubble's CLI toolchain.
        .package(url: "https://github.com/swhitty/SwiftDraw", exact: "0.20.1"),
        .package(url: "https://github.com/lukilabs/beautiful-mermaid-swift", from: "1.0.4"),
    ],
    targets: [
        .target(
            name: "BubbleMounts",
            path: "Sources/BubbleMounts"
        ),
        .target(
            name: "BubbleDiagramSupport",
            path: "Sources/BubbleDiagramSupport"
        ),
        .executableTarget(
            name: "Bubble",
            dependencies: [
                "BubbleMounts",
                "BubbleDiagramSupport",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "LaTeXSwiftUI", package: "LaTeXSwiftUI"),
                .product(name: "BeautifulMermaid", package: "beautiful-mermaid-swift"),
            ],
            path: "Sources/Bubble",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("WebKit"),
                .linkedFramework("Network"),
            ]
        ),
        .executableTarget(
            name: "DiagramChecks",
            dependencies: [
                "BubbleDiagramSupport",
                .product(name: "BeautifulMermaid", package: "beautiful-mermaid-swift"),
            ],
            path: "Tests/DiagramChecks"
        ),
    ]
)
