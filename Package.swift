// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "YiMu",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "YiMu",
            path: "Sources/YiMu",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
