// swift-tools-version: 5.9
import PackageDescription

// Built as a dynamic library so the ARO runtime can dlopen() it.

let package = Package(
    name: "HelloPlugin",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "HelloPlugin", type: .dynamic, targets: ["HelloPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/arolang/aro-plugin-sdk-swift.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "HelloPlugin",
            dependencies: [
                .product(name: "AROPluginSDKExport", package: "aro-plugin-sdk-swift"),
            ],
            path: "Sources"
        ),
    ]
)
