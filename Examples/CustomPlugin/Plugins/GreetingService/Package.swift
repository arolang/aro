// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GreetingService",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "GreetingService", type: .dynamic, targets: ["GreetingService"])
    ],
    dependencies: [
        .package(url: "https://github.com/arolang/aro-plugin-sdk-swift.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "GreetingService",
            dependencies: [
                .product(name: "AROPluginKit", package: "aro-plugin-sdk-swift"),
            ]
        )
    ]
)
