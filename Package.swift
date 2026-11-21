// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Squeeze7z",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Squeeze7zCore", targets: ["Squeeze7zCore"]),
        .executable(name: "Squeeze7z", targets: ["Squeeze7z"]),
        .executable(name: "squeeze7z-cli", targets: ["squeeze7z-cli"]),
    ],
    dependencies: [
        // Software updates for the app bundle (appcast + EdDSA-signed archives).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "Squeeze7zCore"),
        .executableTarget(name: "Squeeze7z", dependencies: [
            "Squeeze7zCore",
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        .executableTarget(name: "squeeze7z-cli", dependencies: ["Squeeze7zCore"]),
        .testTarget(name: "Squeeze7zCoreTests", dependencies: ["Squeeze7zCore"]),
        .testTarget(name: "Squeeze7zAppTests", dependencies: ["Squeeze7z", "Squeeze7zCore"]),
    ],
    swiftLanguageModes: [.v6]
)
