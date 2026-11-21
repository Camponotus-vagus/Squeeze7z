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
    targets: [
        .target(name: "Squeeze7zCore"),
        .executableTarget(name: "Squeeze7z", dependencies: ["Squeeze7zCore"]),
        .executableTarget(name: "squeeze7z-cli", dependencies: ["Squeeze7zCore"]),
        .testTarget(name: "Squeeze7zCoreTests", dependencies: ["Squeeze7zCore"]),
        .testTarget(name: "Squeeze7zAppTests", dependencies: ["Squeeze7z", "Squeeze7zCore"]),
    ],
    swiftLanguageModes: [.v6]
)
