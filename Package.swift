// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HighlightCopy",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "HighlightCopy", targets: ["HighlightCopy"])
    ],
    targets: [
        .target(
            name: "HighlightCopyCore",
            path: "Sources/HighlightCopyCore"
        ),
        .executableTarget(
            name: "HighlightCopy",
            dependencies: ["HighlightCopyCore"],
            path: "Sources/HighlightCopy"
        ),
        .testTarget(
            name: "HighlightCopyTests",
            dependencies: ["HighlightCopyCore"],
            path: "Tests/HighlightCopyTests"
        ),
    ]
)
