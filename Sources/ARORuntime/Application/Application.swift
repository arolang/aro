// ============================================================
// Application.swift
// ARO Runtime - Application Lifecycle
// ============================================================

import Foundation
import AROParser

/// ARO Application
///
/// Manages the lifecycle of an ARO application, including
/// compilation, execution, and shutdown.
public final class Application: @unchecked Sendable {
    // MARK: - Properties

    /// Compiled programs
    private let programs: [AnalyzedProgram]

    /// Entry point feature set name
    private let entryPoint: String

    /// Runtime instance
    private let runtime: Runtime

    /// Application configuration
    private let config: ApplicationConfig

    /// OpenAPI specification (nil if no contract exists)
    public let openAPISpec: OpenAPISpec?

    /// Route registry built from OpenAPI spec
    public let routeRegistry: OpenAPIRouteRegistry?

    /// Whether HTTP server is enabled (requires OpenAPI contract)
    public var isHTTPEnabled: Bool {
        return openAPISpec != nil
    }

    // MARK: - Initialization

    /// Initialize with pre-compiled programs
    public init(
        programs: [AnalyzedProgram],
        entryPoint: String = "Application-Start",
        config: ApplicationConfig = .default,
        openAPISpec: OpenAPISpec? = nil
    ) {
        self.programs = programs
        self.entryPoint = entryPoint
        self.config = config
        self.openAPISpec = openAPISpec
        self.routeRegistry = openAPISpec.map { OpenAPIRouteRegistry(spec: $0) }
        self.runtime = Runtime()

        // Register default services
        registerDefaultServices()
    }

    /// Register default services for the runtime
    private func registerDefaultServices() {
        #if !os(Windows)
        // Register file system service for file operations and monitoring
        let fileSystemService = AROFileSystemService(eventBus: .shared)
        runtime.register(service: fileSystemService as FileSystemService)
        runtime.register(service: fileSystemService as FileMonitorService)

        // Register socket server service for TCP socket operations
        let socketServer = AROSocketServer(eventBus: .shared)
        runtime.register(service: socketServer as SocketServerService)
        #endif
    }

    /// Initialize from source files
    /// - Parameters:
    ///   - sources: Array of (filename, source) tuples
    ///   - entryPoint: Entry point feature set name
    ///   - config: Application configuration
    ///   - openAPISpec: Optional OpenAPI specification
    public convenience init(
        sources: [(String, String)],
        entryPoint: String = "Application-Start",
        config: ApplicationConfig = .default,
        openAPISpec: OpenAPISpec? = nil
    ) throws {
        let compiler = Compiler()
        var programs: [AnalyzedProgram] = []
        var allDiagnostics: [Diagnostic] = []

        for (filename, source) in sources {
            let result = compiler.compile(source)
            allDiagnostics.append(contentsOf: result.diagnostics)

            if result.isSuccess {
                programs.append(result.analyzedProgram)
            }
        }

        let errors = allDiagnostics.filter { $0.severity == .error }
        if !errors.isEmpty {
            throw ApplicationError.compilationFailed(errors)
        }

        self.init(programs: programs, entryPoint: entryPoint, config: config, openAPISpec: openAPISpec)
    }

    // MARK: - Service Registration

    /// Register a service for dependency injection
    public func register<S: Sendable>(service: S) {
        runtime.register(service: service)
    }

    // MARK: - Execution

    /// Run the application
    /// - Returns: The response from the entry point
    @discardableResult
    public func run() async throws -> Response {
        // Merge all programs
        guard let mainProgram = mergedProgram() else {
            throw ApplicationError.noPrograms
        }

        return try await runtime.run(mainProgram, entryPoint: entryPoint)
    }

    /// Run and keep the application alive (for servers)
    public func runForever() async throws {
        guard let mainProgram = mergedProgram() else {
            throw ApplicationError.noPrograms
        }

        try await runtime.runAndKeepAlive(mainProgram, entryPoint: entryPoint)
    }

    /// Stop the application
    public func stop() {
        runtime.stop()
    }

    // MARK: - Private

    private func mergedProgram() -> AnalyzedProgram? {
        guard !programs.isEmpty else { return nil }

        if programs.count == 1 {
            return programs[0]
        }

        // Merge multiple programs into one
        var allFeatureSets: [AnalyzedFeatureSet] = []
        let globalRegistry = GlobalSymbolRegistry()

        for program in programs {
            allFeatureSets.append(contentsOf: program.featureSets)

            // Merge global registries
            for (name, info) in program.globalRegistry.allPublished {
                globalRegistry.register(symbol: info.symbol, fromFeatureSet: info.featureSet)
            }
        }

        // Create merged AST program
        let mergedASTFeatureSets = allFeatureSets.map { $0.featureSet }
        let mergedAST = Program(
            featureSets: mergedASTFeatureSets,
            span: programs[0].program.span
        )

        return AnalyzedProgram(
            program: mergedAST,
            featureSets: allFeatureSets,
            globalRegistry: globalRegistry
        )
    }
}

// MARK: - Application Configuration

/// Configuration for ARO applications
public struct ApplicationConfig: Sendable {
    /// Whether to enable verbose logging
    public let verbose: Bool

    /// Working directory
    public let workingDirectory: String

    /// Environment variables
    public let environment: [String: String]

    /// Default configuration
    public static let `default` = ApplicationConfig(
        verbose: false,
        workingDirectory: ".",
        environment: [:]
    )

    public init(
        verbose: Bool = false,
        workingDirectory: String = ".",
        environment: [String: String] = [:]
    ) {
        self.verbose = verbose
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

// MARK: - Application Errors

/// Errors that can occur during application lifecycle
public enum ApplicationError: Error, Sendable {
    case compilationFailed([Diagnostic])
    case noPrograms
    case entryPointNotFound(String)
    case sourceFileNotFound(String)
    case invalidConfiguration(String)
}

extension ApplicationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .compilationFailed(let diagnostics):
            let messages = diagnostics.map { $0.description }.joined(separator: "\n")
            return "Compilation failed:\n\(messages)"
        case .noPrograms:
            return "No programs to execute"
        case .entryPointNotFound(let name):
            return "Entry point '\(name)' not found"
        case .sourceFileNotFound(let path):
            return "Source file not found: \(path)"
        case .invalidConfiguration(let reason):
            return "Invalid configuration: \(reason)"
        }
    }
}

// MARK: - Application Discovery

/// Discovers and loads ARO applications from directories
public struct ApplicationDiscovery {
    public init() {}

    /// Discover an application at a path
    /// - Parameters:
    ///   - path: Directory or file path
    ///   - entryPoint: Entry point feature set name
    /// - Returns: Application configuration
    public func discover(
        at path: URL,
        entryPoint: String = "Application-Start"
    ) async throws -> DiscoveredApplication {
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
            throw ApplicationError.sourceFileNotFound(path.path)
        }

        let sourceFiles: [URL]
        let rootPath: URL

        if isDirectory.boolValue {
            // Find all .aro files in directory
            sourceFiles = try findSourceFiles(in: path)
            rootPath = path
        } else {
            // Single file
            sourceFiles = [path]
            rootPath = path.deletingLastPathComponent()
        }

        // Check for OpenAPI contract
        let openAPISpec = try loadOpenAPISpec(from: rootPath)

        return DiscoveredApplication(
            rootPath: rootPath,
            sourceFiles: sourceFiles,
            entryPointFeatureSet: entryPoint,
            openAPISpec: openAPISpec,
            hasOpenAPIContract: openAPISpec != nil
        )
    }

    /// Load OpenAPI specification from a directory
    private func loadOpenAPISpec(from directory: URL) throws -> OpenAPISpec? {
        guard let spec = try OpenAPILoader.load(fromDirectory: directory) else {
            return nil
        }

        // Validate the spec
        try spec.validate()
        try ContractValidator.validateSpec(spec)

        return spec
    }

    private func findSourceFiles(in directory: URL) throws -> [URL] {
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var sourceFiles: [URL] = []

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if ext == "fdd" || ext == "aro" {
                sourceFiles.append(fileURL)
            }
        }

        // Sort so main.aro comes first
        sourceFiles.sort { url1, url2 in
            let name1 = url1.deletingPathExtension().lastPathComponent
            let name2 = url2.deletingPathExtension().lastPathComponent
            if name1 == "main" { return true }
            if name2 == "main" { return false }
            return url1.path < url2.path
        }

        return sourceFiles
    }
}

/// Result of application discovery
public struct DiscoveredApplication: Sendable {
    /// Root directory of the application
    public let rootPath: URL

    /// All source files found
    public let sourceFiles: [URL]

    /// The entry point feature set name
    public let entryPointFeatureSet: String

    /// OpenAPI specification (if contract exists)
    public let openAPISpec: OpenAPISpec?

    /// Whether an OpenAPI contract was found
    public let hasOpenAPIContract: Bool
}
