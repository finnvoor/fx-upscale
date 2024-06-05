// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "fx-upscale",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .executable(name: "fx-upscale", targets: ["fx-upscale"]),
        .library(name: "Upscaling", targets: ["Upscaling"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/Finnvoor/SwiftTUI.git", from: "1.0.4")
    ],
    targets: [
        .executableTarget(
            name: "fx-upscale",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftTUI", package: "SwiftTUI"),
                "Upscaling"
            ]
        ),
        .target(name: "Upscaling"),
        .testTarget(
            name: "UpscalingTests",
            dependencies: ["Upscaling"],
            resources: [.process("Resources")]
        )
    ]
)
