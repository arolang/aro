// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SQLitePlugin",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "SQLitePlugin", type: .dynamic, targets: ["SQLitePlugin"])
    ],
    dependencies: [
        // Use 0.14.1 which has simpler Linux support without traits
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", exact: "0.14.1"),
        .package(url: "https://github.com/arolang/aro-plugin-sdk-swift.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "SQLitePlugin",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "AROPluginSDK", package: "aro-plugin-sdk-swift"),
            ]
        )
    ]
)
