// swift-tools-version: 6.2
import PackageDescription

// Platform-specific dependencies
// swift-nio and async-http-client have Windows compatibility issues
var platformDependencies: [Package.Dependency] = []
var runtimePlatformDependencies: [Target.Dependency] = []

#if !os(Windows)
platformDependencies = [
    // SwiftNIO for HTTP server and sockets (2.75.0+ for Swift 6 support)
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.75.0"),
    // AsyncHTTPClient for outgoing HTTP requests
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    // FileMonitor for file system watching
    .package(url: "https://github.com/aus-der-Technik/FileMonitor.git", from: "1.0.0"),
]
runtimePlatformDependencies = [
    .product(name: "NIO", package: "swift-nio"),
    .product(name: "NIOHTTP1", package: "swift-nio"),
    .product(name: "NIOFoundationCompat", package: "swift-nio"),
    .product(name: "AsyncHTTPClient", package: "async-http-client"),
    .product(name: "FileMonitor", package: "FileMonitor"),
]
#endif

let package = Package(
    name: "AROParser",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "AROParser",
            targets: ["AROParser"]
        ),
        // ARORuntime is now a static library that exports C symbols via @_cdecl
        // for use by compiled ARO binaries (previously this was in AROCRuntime)
        .library(
            name: "ARORuntime",
            type: .static,
            targets: ["ARORuntime"]
        ),
        .library(
            name: "AROCompiler",
            targets: ["AROCompiler"]
        ),
        .executable(
            name: "aro",
            targets: ["AROCLI"]
        )
    ],
    dependencies: platformDependencies + [
        // Swift Argument Parser for CLI
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Yams for YAML parsing (OpenAPI contracts)
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
    ],
    targets: [
        // Core parser library
        .target(
            name: "AROParser",
            path: "Sources/AROParser"
        ),
        // Runtime library
        .target(
            name: "ARORuntime",
            dependencies: [
                "AROParser",
                .product(name: "Yams", package: "Yams"),
            ] + runtimePlatformDependencies,
            path: "Sources/ARORuntime"
        ),
        // Native compiler (LLVM IR generation)
        .target(
            name: "AROCompiler",
            dependencies: [
                "AROParser",
            ],
            path: "Sources/AROCompiler"
        ),
        // CLI tool
        .executableTarget(
            name: "AROCLI",
            dependencies: [
                "AROParser",
                "ARORuntime",
                "AROCompiler",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AROCLI"
        ),
        // Parser tests
        .testTarget(
            name: "AROParserTests",
            dependencies: ["AROParser"],
            path: "Tests/AROParserTests"
        ),
        // Runtime tests
        .testTarget(
            name: "AROuntimeTests",
            dependencies: ["ARORuntime"],
            path: "Tests/AROuntimeTests"
        ),
        // Compiler tests
        .testTarget(
            name: "AROCompilerTests",
            dependencies: ["AROCompiler", "AROParser"],
            path: "Tests/AROCompilerTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
