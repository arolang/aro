// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CounterPlugin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CounterPlugin", type: .dynamic, targets: ["CounterPlugin"])
    ],
    targets: [
        .target(
            name: "CounterPlugin",
            dependencies: []
        )
    ]
)
