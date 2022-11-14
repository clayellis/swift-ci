// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "swift-ci",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "SwiftCI", targets: ["SwiftCI"]),
        .executable(name: "Demo", targets: ["Demo"])
    ],
    dependencies: [
        .package(url: "https://github.com/clayellis/swift-arguments", branch: "main"),
        .package(url: "https://github.com/clayellis/swift-environment", branch: "main"),
        .package(url: "https://github.com/apple/swift-log", from: "1.4.4"),
        .package(url: "https://github.com/JohnSundell/ShellOut", from: "2.3.0")
    ],
    targets: [
        .target(
            name: "SwiftCI",
            dependencies: [
                .product(name: "Arguments", package: "swift-arguments"),
                .product(name: "ShellOut", package: "ShellOut"),
                .product(name: "SwiftEnvironment", package: "swift-environment"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "SwiftCITests",
            dependencies: ["SwiftCI"]
        ),
        .executableTarget(name: "Demo", dependencies: ["SwiftCI"])
    ]
)
