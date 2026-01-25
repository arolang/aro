// swift-tools-version: 6.2
import PackageDescription

// Platform-specific dependencies
// On Windows: use Joannis's SwiftNIO fork with WSAPoll support
// On macOS/Linux: use official SwiftNIO releases
var platformDependencies: [Package.Dependency] = []
var runtimePlatformDependencies: [Target.Dependency] = []
var lspDependencies: [Package.Dependency] = []
var lspTargetDependencies: [Target.Dependency] = []
var cliLspDependency: [Target.Dependency] = []
var compilerLLVMDependency: [Target.Dependency] = []

#if os(Windows)
// Windows-specific dependencies
// Use Joannis's SwiftNIO fork with WSAPoll support for Windows networking
platformDependencies = [
    // Joannis's SwiftNIO fork with Windows WSAPoll support (PR #3433)
    .package(url: "https://github.com/Joannis/swift-nio.git", branch: "main"),
    // AsyncHTTPClient for outgoing HTTP requests
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    // LLVM C API bindings for type-safe IR generation
    .package(url: "https://github.com/hylo-lang/Swifty-LLVM.git", branch: "main"),
    // SwiftSoup for HTML/XML parsing (pure Swift, works on all platforms)
    .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
]
runtimePlatformDependencies = [
    .product(name: "NIO", package: "swift-nio"),
    .product(name: "NIOHTTP1", package: "swift-nio"),
    .product(name: "NIOFoundationCompat", package: "swift-nio"),
    .product(name: "AsyncHTTPClient", package: "async-http-client"),
    .product(name: "SwiftSoup", package: "SwiftSoup"),
]
// LLVM for native compilation on Windows
compilerLLVMDependency = [
    .product(name: "SwiftyLLVM", package: "Swifty-LLVM"),
]
// LSP not available on Windows yet - JSONRPC has issues
#else
// macOS and Linux dependencies
platformDependencies = [
    // SwiftNIO for HTTP server and sockets (2.75.0+ for Swift 6 support)
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.75.0"),
    // AsyncHTTPClient for outgoing HTTP requests
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    // FileMonitor for file system watching
    .package(url: "https://github.com/KrisSimon/FileMonitor.git", from: "2.0.0"),
    // LLVM C API bindings for type-safe IR generation (Issue #53)
    // Swifty-LLVM requires Swift 6.2 and LLVM 20
    .package(url: "https://github.com/hylo-lang/Swifty-LLVM.git", branch: "main"),
    // SwiftSoup for HTML/XML parsing (pure Swift, works on all platforms)
    .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
]
runtimePlatformDependencies = [
    .product(name: "NIO", package: "swift-nio"),
    .product(name: "NIOHTTP1", package: "swift-nio"),
    .product(name: "NIOFoundationCompat", package: "swift-nio"),
    .product(name: "AsyncHTTPClient", package: "async-http-client"),
    .product(name: "FileMonitor", package: "FileMonitor"),
    .product(name: "SwiftSoup", package: "SwiftSoup"),
]
// LSP dependencies (JSONRPC doesn't support Windows)
lspDependencies = [
    .package(url: "https://github.com/ChimeHQ/LanguageServerProtocol", from: "0.14.0"),
]
lspTargetDependencies = [
    .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol"),
]
cliLspDependency = [
    "AROLSP",
]
// LLVM C API for type-safe IR generation
compilerLLVMDependency = [
    .product(name: "SwiftyLLVM", package: "Swifty-LLVM"),
]
#endif

// LLVM linker settings - pkg-config needs help finding LLVM
#if os(macOS)
import Foundation
let llvmPath = ProcessInfo.processInfo.environment["LLVM_PATH"] ?? "/opt/homebrew/opt/llvm@20"
let llvmLibPath = "\(llvmPath)/lib"
let llvmLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L\(llvmLibPath)", "-lLLVM-20"]),
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", llvmLibPath]),
]
#elseif os(Linux)
import Foundation
let llvmPath = ProcessInfo.processInfo.environment["LLVM_PATH"] ?? "/usr/lib/llvm-20"
let llvmLibPath = "\(llvmPath)/lib"
let llvmLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L\(llvmLibPath)", "-lLLVM-20"]),
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", llvmLibPath]),
]
#elseif os(Windows)
import Foundation
// Windows LLVM paths - check environment or use common locations
let llvmPath = ProcessInfo.processInfo.environment["LLVM_PATH"] ?? "C:\\Program Files\\LLVM"
let llvmLibPath = "\(llvmPath)\\lib"
let llvmLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L\(llvmLibPath)", "-lLLVM"]),
]
#else
let llvmLinkerSettings: [LinkerSetting] = []
#endif

let package = Package(
    name: "AROParser",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
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
    dependencies: platformDependencies + lspDependencies + [
        // Swift Argument Parser for CLI
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Yams for YAML parsing (OpenAPI contracts)
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
        // Swift Crypto for cryptographic operations (SHA256, etc.)
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
    ],
    targets: {
        // Core targets available on all platforms
        var targets: [Target] = [
            // Version information library
            .target(
                name: "AROVersion",
                path: "Sources/AROVersion"
            ),
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
                    .product(name: "Crypto", package: "swift-crypto"),
                ] + runtimePlatformDependencies,
                path: "Sources/ARORuntime"
            ),
            // Native compiler (LLVM IR generation)
            .target(
                name: "AROCompiler",
                dependencies: [
                    "AROParser",
                ] + compilerLLVMDependency,
                path: "Sources/AROCompiler",
                linkerSettings: llvmLinkerSettings
            ),
            // CLI tool
            .executableTarget(
                name: "AROCLI",
                dependencies: [
                    "AROVersion",
                    "AROParser",
                    "ARORuntime",
                    "AROCompiler",
                    .product(name: "ArgumentParser", package: "swift-argument-parser"),
                ] + cliLspDependency,
                path: "Sources/AROCLI",
                linkerSettings: llvmLinkerSettings
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
            ),
        ]

        // LSP targets - not available on Windows (no compatible library)
        #if !os(Windows)
        targets.append(contentsOf: [
            // Language Server Protocol implementation
            .target(
                name: "AROLSP",
                dependencies: [
                    "AROParser",
                ] + lspTargetDependencies,
                path: "Sources/AROLSP"
            ),
            // LSP tests
            .testTarget(
                name: "AROLSPTests",
                dependencies: ["AROLSP", "AROParser"] + lspTargetDependencies,
                path: "Tests/AROLSPTests"
            ),
        ])
        #endif

        return targets
    }(),
    swiftLanguageModes: [.v6]
)
