// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Fungi",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Fungi", targets: ["Fungi"])
    ],
    dependencies: [
        // Spore Cloud HTTP server (BSD-3-Clause)
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0"),
        // Breeze audio output switching (MIT)
        .package(url: "https://github.com/rnine/SimplyCoreAudio.git", from: "4.1.1"),
        // User-configurable global hotkeys (MIT)
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "1.10.0")
    ],
    targets: [
        .executableTarget(
            name: "Fungi",
            dependencies: [
                .product(name: "Swifter", package: "swifter"),
                .product(name: "SimplyCoreAudio", package: "SimplyCoreAudio"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources/Fungi"
        )
    ]
)
