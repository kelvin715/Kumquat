// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Kumquat",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Kumquat", targets: ["Kumquat"]),
        .library(name: "KumquatCore", targets: ["KumquatCore"]),
    ],
    targets: [
        .target(
            name: "KumquatCore",
            path: "Sources/KumquatCore"
        ),
        .executableTarget(
            name: "Kumquat",
            dependencies: ["KumquatCore"],
            path: "Sources/Kumquat"
        ),
        .testTarget(
            name: "KumquatCoreTests",
            dependencies: ["KumquatCore"],
            path: "Tests/KumquatCoreTests"
        ),
    ]
)
