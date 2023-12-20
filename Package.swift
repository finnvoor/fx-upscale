// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MetalFXUpscale",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MetalFXUpscale", targets: ["MetalFXUpscale"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "MetalFXUpscale",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
    ]
)
