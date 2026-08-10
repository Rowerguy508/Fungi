// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Fungi",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Fungi", targets: ["Fungi"])
    ],
    targets: [
        .executableTarget(
            name: "Fungi",
            path: "Sources/Fungi"
        )
    ]
)