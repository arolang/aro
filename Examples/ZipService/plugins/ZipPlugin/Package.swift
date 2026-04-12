// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZipPlugin",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "ZipPlugin", type: .dynamic, targets: ["ZipPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/marmelroy/Zip.git", exact: "2.1.1"),
        .package(url: "https://github.com/arolang/aro-plugin-sdk-swift.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "ZipPlugin",
            dependencies: [
                .product(name: "Zip", package: "Zip"),
                .product(name: "AROPluginSDKExport", package: "aro-plugin-sdk-swift"),
            ]
        )
    ]
)
