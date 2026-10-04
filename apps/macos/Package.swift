// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Luna",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "Luna",
            dependencies: [
                "KeyboardShortcuts",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LunaTests",
            dependencies: ["Luna"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
