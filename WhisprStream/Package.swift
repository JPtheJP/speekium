// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhisprStream",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WhisprStream", targets: ["WhisprStream"]),
        .executable(
            name: "WhisprStreamUpdateInstaller",
            targets: ["WhisprStreamUpdateInstaller"]
        ),
        .executable(
            name: "WhisprStreamUpdateSigner",
            targets: ["WhisprStreamUpdateSigner"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "WhisprStream",
            path: "Sources/WhisprStream",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "WhisprStreamUpdateInstaller",
            path: "Sources/WhisprStreamUpdateInstaller",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "WhisprStreamUpdateSigner",
            path: "Tools/WhisprStreamUpdateSigner",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WhisprStreamTests",
            dependencies: ["WhisprStream"],
            path: "Tests/WhisprStreamTests"
        )
    ]
)
