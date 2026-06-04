// swift-tools-version: 6.2
import PackageDescription

// Platform-specific dependencies
// On Windows: use FlyingFox for HTTP server (polling-based, no NIO dependency)
// On macOS/Linux: use official SwiftNIO releases
var platformDependencies: [Package.Dependency] = []
var runtimePlatformDependencies: [Target.Dependency] = []
var lspDependencies: [Package.Dependency] = []
var lspTargetDependencies: [Target.Dependency] = []
var cliLspDependency: [Target.Dependency] = []
var compilerLLVMDependency: [Target.Dependency] = []
var mlxDependencies: [Package.Dependency] = []
var askMLXTargetDependencies: [Target.Dependency] = []

#if os(Windows)
// Windows-specific dependencies
// FlyingFox provides HTTP server and sockets without NIO (uses polling on Windows)
platformDependencies = [
    // FlyingFox for HTTP server (includes FlyingSocks for socket support)
    .package(url: "https://github.com/swhitty/FlyingFox.git", from: "0.21.0"),
    // SwiftSoup for HTML/XML parsing (pure Swift, works on all platforms)
    .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
]
runtimePlatformDependencies = [
    .product(name: "FlyingFox", package: "FlyingFox"),
    .product(name: "FlyingSocks", package: "FlyingFox"),
    .product(name: "SwiftSoup", package: "SwiftSoup"),
]
// LLVM/native compilation not available on Windows yet (requires LLVM installation)
// LSP not available on Windows yet - JSONRPC has issues
#else
// macOS and Linux dependencies
platformDependencies = [
    // SwiftNIO for HTTP server and sockets (2.75.0+ for Swift 6 support)
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.75.0"),
    // AsyncHTTPClient for outgoing HTTP requests
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    // FileMonitor for file system watching
    .package(url: "https://github.com/KrisSimon/FileMonitor.git", from: "2.1.0"),
    // LLVM C API bindings for type-safe IR generation (Issue #53)
    // Swifty-LLVM requires Swift 6.2 and LLVM 20
    .package(url: "https://github.com/hylo-lang/Swifty-LLVM.git", branch: "main"),
    // SwiftSoup for HTML/XML parsing (pure Swift, works on all platforms)
    .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
]
runtimePlatformDependencies = [
    .product(name: "NIO", package: "swift-nio"),
    .product(name: "NIOHTTP1", package: "swift-nio"),
    .product(name: "NIOWebSocket", package: "swift-nio"),
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

// Issue #228 — SOLARO desktop app (macOS only). The product + target
// + test wiring is gated here so Linux/Windows builds don't trip on
// the AppKit/SwiftUI imports. See ADR-001 follow-up note about the
// SwiftCrossUI -> native-SwiftUI pivot.
var solaroProducts: [Product] = []
var solaroTargets: [Target] = []
#if os(macOS)
solaroProducts = [
    .executable(
        name: "SolaroApp",
        targets: ["SOLARO"]
    ),
    .executable(
        name: "solaro",
        targets: ["SOLAROLauncher"]
    ),
]
solaroTargets = [
    .executableTarget(
        name: "SOLARO",
        dependencies: [
            "AROVersion",
            "AROParser",
            "ARORuntime",
            .product(name: "Logging", package: "swift-log"),
            .product(name: "Yams", package: "Yams"),
            // STTextView (TextKit 2 editor) for the code-editing pane —
            // gives us a gutter, proper attributed-text editing, and
            // a plugin surface for syntax highlighting + breakpoints.
            .product(name: "STTextView", package: "STTextView"),
            // SwiftTerm — ANSI terminal emulator for the bottom panel.
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ],
        path: "Sources/SOLARO"
    ),
    .executableTarget(
        name: "SOLAROLauncher",
        dependencies: [
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ],
        path: "Sources/SOLAROLauncher"
    ),
    .testTarget(
        name: "SOLAROTests",
        dependencies: ["SOLARO"],
        path: "Tests/SOLAROTests"
    ),
]
#endif

// MLX dependencies — macOS Apple Silicon only (Linux uses llama.cpp/CUDA)
#if os(macOS)
mlxDependencies = [
    .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", branch: "main"),
    // 1.3.0+ avoids a Swift 6.2.1 SIL OwnershipModelEliminator crash that
    // 0.1.8 triggered while compiling Tokenizers' LeavesWithCommonPrefixIterator.
    .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
]
askMLXTargetDependencies = [
    .product(name: "MLXLLM", package: "mlx-swift-lm"),
    .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
    .product(name: "Transformers", package: "swift-transformers"),
]
#endif

// LLVM linker settings - pkg-config needs help finding LLVM
#if os(macOS)
import Foundation
let llvmPath = ProcessInfo.processInfo.environment["LLVM_PATH"] ?? "/opt/homebrew/opt/llvm@20"
let llvmLibPath = "\(llvmPath)/lib"
let llvmIncludePath = "\(llvmPath)/include"
let llvmLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L\(llvmLibPath)", "-lLLVM-20"]),
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", llvmLibPath]),
]
#elseif os(Linux)
import Foundation
let llvmPath = ProcessInfo.processInfo.environment["LLVM_PATH"] ?? "/usr/lib/llvm-20"
let llvmLibPath = "\(llvmPath)/lib"
let llvmIncludePath = "\(llvmPath)/include"
let llvmLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-L\(llvmLibPath)", "-lLLVM-20"]),
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", llvmLibPath]),
]
#else
// Windows and other platforms: LLVM not available
let llvmPath = ""
let llvmLibPath = ""
let llvmIncludePath = ""
let llvmLinkerSettings: [LinkerSetting] = []
#endif

// Issue #231 — C bridge target exposing llvm-c/DebugInfo.h to Swift so
// AROCompiler can emit DWARF metadata. Swifty-LLVM's bundled `llvmc`
// module only covers Core.h.
let arocDebugInfoCSettings: [CSetting] = [
    .headerSearchPath("include"),
    .unsafeFlags(["-I\(llvmIncludePath)"], .when(platforms: [.macOS, .linux])),
]

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
        .library(
            name: "AROPackageManager",
            targets: ["AROPackageManager"]
        ),
        .executable(
            name: "aro",
            targets: ["AROCLI"]
        ),
        // SOLARO products (macOS only) are appended via `solaroProducts`
        // below — see the top of this file for the gated definition.
    ] + solaroProducts,
    dependencies: platformDependencies + lspDependencies + mlxDependencies + [
        // Swift Argument Parser for CLI
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Yams for YAML parsing (OpenAPI contracts)
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
        // Swift Crypto for cryptographic operations (SHA256, etc.)
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        // LineNoise for REPL line editing (arrow keys, history)
        .package(url: "https://github.com/andybest/linenoise-swift.git", from: "0.0.3"),
        // Swift Log for structured logging
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        // STTextView — TextKit 2 editor used by SOLARO's center pane.
        // Pinned to the minor while the API is still settling.
        .package(url: "https://github.com/krzyzanowskim/STTextView.git", from: "2.3.10"),
        // SwiftTerm — real ANSI terminal emulator for the bottom
        // panel's Terminal tab (#244).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: {
        // AROAsk dependencies (non-Windows)
        #if !os(Windows)
        let askDependency: [Target.Dependency] = ["AROAsk"]
        #else
        let askDependency: [Target.Dependency] = []
        #endif

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
                    "Clibgit2",
                    .product(name: "Yams", package: "Yams"),
                    .product(name: "Crypto", package: "swift-crypto"),
                    .product(name: "Logging", package: "swift-log"),
                ] + runtimePlatformDependencies,
                path: "Sources/ARORuntime"
            ),
            // Issue #231 — C bridge target exposing llvm-c/DebugInfo.h
            // to Swift for DWARF source-mapping emission.
            .target(
                name: "AROCDebugInfo",
                path: "Sources/AROCDebugInfo",
                publicHeadersPath: "include",
                cSettings: arocDebugInfoCSettings
            ),
            // Native compiler (LLVM IR generation)
            .target(
                name: "AROCompiler",
                dependencies: [
                    "AROParser",
                    "AROCDebugInfo",
                    .product(name: "Logging", package: "swift-log"),
                ] + compilerLLVMDependency,
                path: "Sources/AROCompiler",
                linkerSettings: llvmLinkerSettings
            ),
            // System library for libgit2
            .systemLibrary(
                name: "Clibgit2",
                path: "Sources/Clibgit2",
                pkgConfig: "libgit2",
                providers: [
                    .brew(["libgit2"]),
                    .apt(["libgit2-dev"]),
                ]
            ),
            // Package manager for plugins
            .target(
                name: "AROPackageManager",
                dependencies: [
                    "Clibgit2",
                    .product(name: "Yams", package: "Yams"),
                ],
                path: "Sources/AROPackageManager"
            ),
            // CLI tool
            .executableTarget(
                name: "AROCLI",
                dependencies: [
                    "AROVersion",
                    "AROParser",
                    "ARORuntime",
                    "AROCompiler",
                    "AROPackageManager",
                    .product(name: "ArgumentParser", package: "swift-argument-parser"),
                    .product(name: "LineNoise", package: "linenoise-swift"),
                    .product(name: "Logging", package: "swift-log"),
                ] + cliLspDependency + askDependency,
                path: "Sources/AROCLI",
                linkerSettings: llvmLinkerSettings
            ),
            // SOLARO targets (macOS only) are appended below via
            // `solaroTargets` — see the top of this file.
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
            // Package manager tests
            .testTarget(
                name: "AROPackageManagerTests",
                dependencies: ["AROPackageManager"],
                path: "Tests/AROPackageManagerTests"
            ),
            // CLI tests — covers the small pieces of pure logic that
            // live inside CLI command structs (e.g. UILauncher path
            // resolution). Uses @testable import AROCLI.
            .testTarget(
                name: "AROCLITests",
                dependencies: ["AROCLI"],
                path: "Tests/AROCLITests"
            ),
        ]

        // SOLARO targets (macOS only) — appended unconditionally; the
        // array is empty on non-macOS hosts.
        targets.append(contentsOf: solaroTargets)

        // LSP targets - not available on Windows (no compatible library)
        #if !os(Windows)
        targets.append(contentsOf: [
            // Language Server Protocol implementation
            .target(
                name: "AROLSP",
                dependencies: [
                    "AROParser",
                    "ARORuntime",
                ] + lspTargetDependencies,
                path: "Sources/AROLSP"
            ),
            // LSP tests
            .testTarget(
                name: "AROLSPTests",
                dependencies: ["AROLSP", "AROParser"] + lspTargetDependencies,
                path: "Tests/AROLSPTests"
            ),
            // AROAsk - local LLM coding assistant (`aro ask`)
            // On macOS: native MLX inference (MLXLLM + Transformers)
            // On Linux: llama-server (CUDA) or remote endpoint
            .target(
                name: "AROAsk",
                dependencies: [
                    "AROParser",
                    "ARORuntime",
                    "AROVersion",
                    .product(name: "ArgumentParser", package: "swift-argument-parser"),
                    .product(name: "Yams", package: "Yams"),
                    .product(name: "Crypto", package: "swift-crypto"),
                    .product(name: "LineNoise", package: "linenoise-swift"),
                ] + askMLXTargetDependencies,
                path: "Sources/AROAsk"
            ),
        ])
        #endif

        return targets
    }(),
    swiftLanguageModes: [.v6]
)
