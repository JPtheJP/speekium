// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhisprStream",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WhisprStream",
            path: "Sources/WhisprStream",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
