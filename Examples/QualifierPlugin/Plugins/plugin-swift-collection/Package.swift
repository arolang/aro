// swift-tools-version: 5.9
import PackageDescription

// Built as a dynamic library so the ARO runtime can dlopen() it.

let package = Package(
    name: "CollectionPlugin",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "CollectionPlugin", type: .dynamic, targets: ["CollectionPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/arolang/aro-plugin-sdk-swift.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "CollectionPlugin",
            dependencies: [
                .product(name: "AROPluginSDK", package: "aro-plugin-sdk-swift"),
            ],
            path: "Sources"
        ),
    ]
)
