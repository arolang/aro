// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SQLitePlugin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SQLitePlugin", type: .dynamic, targets: ["SQLitePlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.0")
    ],
    targets: [
        .target(
            name: "SQLitePlugin",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift")
            ]
        )
    ]
)
