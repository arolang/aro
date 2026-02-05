// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ZipPlugin",
    products: [
        .library(name: "ZipPlugin", type: .dynamic, targets: ["ZipPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/marmelroy/Zip.git", exact: "2.1.1")
    ],
    targets: [
        .target(
            name: "ZipPlugin",
            dependencies: [
                .product(name: "Zip", package: "Zip")
            ]
        )
    ],
    // Force Swift 5 language mode for the entire package graph
    // to work around Zip library not being Swift 6 compatible
    swiftLanguageModes: [.v5]
)
