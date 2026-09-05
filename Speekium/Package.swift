// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Speekium",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Speekium", targets: ["Speekium"]),
        .executable(
            name: "SpeekiumUpdateInstaller",
            targets: ["SpeekiumUpdateInstaller"]
        ),
        .executable(
            name: "SpeekiumUpdateSigner",
            targets: ["SpeekiumUpdateSigner"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "Speekium",
            path: "Sources/Speekium",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SpeekiumUpdateInstaller",
            path: "Sources/SpeekiumUpdateInstaller",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SpeekiumUpdateSigner",
            path: "Tools/SpeekiumUpdateSigner",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SpeekiumTests",
            dependencies: ["Speekium"],
            path: "Tests/SpeekiumTests"
        )
    ]
)
