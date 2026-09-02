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
        .library(name: "BubbleSessions", targets: ["BubbleSessions"]),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
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
        .target(
            name: "BubbleSessions",
            path: "Sources/BubbleSessions"
        ),
        .executableTarget(
            name: "Bubble",
            dependencies: [
                "BubbleMounts",
                "BubbleSessions",
                "BubbleDiagramSupport",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
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
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMedia"),
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
        .executableTarget(
            name: "SessionTabsChecks",
            dependencies: ["BubbleSessions"],
            path: "Tests/SessionTabsChecks"
        ),
    ]
)
