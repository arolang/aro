// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CounterPlugin",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "CounterPlugin", type: .dynamic, targets: ["CounterPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/arolang/aro-plugin-sdk-swift.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "CounterPlugin",
            dependencies: [
                .product(name: "AROPluginKit", package: "aro-plugin-sdk-swift"),
            ]
        )
    ]
)
