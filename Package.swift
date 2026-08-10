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
        // User-configurable global hotkeys (MIT). Pinned to last stable v1.x
        // because 3.x uses #Preview macros + Swift 6 toolchain that breaks
        // SwiftPM build. See https://github.com/sindresorhus/KeyboardShortcuts
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", exact: "1.10.0")
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
