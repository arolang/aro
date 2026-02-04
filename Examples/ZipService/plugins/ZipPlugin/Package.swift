// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZipPlugin",
    products: [
        .library(name: "ZipPlugin", type: .dynamic, targets: ["ZipPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/marmelroy/Zip.git", from: "2.1.0")
    ],
    targets: [
        .target(
            name: "ZipPlugin",
            dependencies: [
                .product(name: "Zip", package: "Zip")
            ]
        )
    ]
)
