// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Speekium",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Speekium",
            path: "Sources/Speekium",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SpeekiumTests",
            dependencies: ["Speekium"],
            path: "Tests/SpeekiumTests"
        )
    ]
)
