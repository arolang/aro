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

    /// HTTP server instance for setting request handler
    #if os(Windows)
    private var httpServer: WindowsHTTPServer?
    #else
    private var httpServer: AROHTTPServer?
    #endif

    /// Template service for HTML template rendering (ARO-0050)
    private var templateService: AROTemplateService?

    /// Event recorder for debugging (ARO-0007, GitLab #124)
    private let eventRecorder: EventRecorder

    /// Path to record events to (optional)
    private let recordPath: String?

    /// Path to replay events from (optional)
    private let replayPath: String?

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
        openAPISpec: OpenAPISpec? = nil,
        recordPath: String? = nil,
        replayPath: String? = nil
    ) {
        self.programs = programs
        self.entryPoint = entryPoint
        self.config = config
        self.openAPISpec = openAPISpec
        self.routeRegistry = openAPISpec.map { OpenAPIRouteRegistry(spec: $0) }
        self.runtime = Runtime()
        self.eventRecorder = EventRecorder(eventBus: .shared)
        self.recordPath = recordPath
        self.replayPath = replayPath
        // Services are registered when run() is called (async context)
    }

    /// Register default services for the runtime
    private func registerDefaultServices() async {
        // Register repository storage service for persistent in-memory storage
        await runtime.register(service: InMemoryRepositoryStorage.shared as RepositoryStorageService)

        #if os(Windows)
        // Windows-specific service implementations
        // Register file system service for file operations
        let fileSystemService = AROFileSystemService(eventBus: .shared)
        await runtime.register(service: fileSystemService as FileSystemService)

        // Register Windows file monitor (polling-based)
        let fileMonitor = WindowsFileMonitor(eventBus: .shared)
        await runtime.register(service: fileMonitor as FileMonitorService)

        // Register Windows socket server (FlyingSocks-based)
        let socketServer = WindowsSocketServer(eventBus: .shared)
        await runtime.register(service: socketServer as SocketServerService)

        // Register Windows HTTP server (FlyingFox-based)
        let server = WindowsHTTPServer(eventBus: .shared)
        self.httpServer = server
        await runtime.register(service: server as HTTPServerService)
        #else
        // Register file system service for file operations and monitoring
        let fileSystemService = AROFileSystemService(eventBus: .shared)
        await runtime.register(service: fileSystemService as FileSystemService)
        await runtime.register(service: fileSystemService as FileMonitorService)

        // Register socket server service for TCP socket operations
        let socketServer = AROSocketServer(eventBus: .shared)
        await runtime.register(service: socketServer as SocketServerService)

        // Register HTTP server service for web APIs
        // WebSocket is configured on-demand via: <Start> the <http-server> with { websocket: "/ws" }.
        let server = AROHTTPServer(eventBus: .shared)
        self.httpServer = server
        await runtime.register(service: server as HTTPServerService)
        #endif

        // Register OpenAPI spec service if contract exists
        if let spec = openAPISpec {
            let specService = OpenAPISpecService(spec: spec)
            await runtime.register(service: specService)
        }

        // Register template service (ARO-0050)
        let templatesDirectory = (config.workingDirectory as NSString).appendingPathComponent("templates")
        let ts = AROTemplateService(templatesDirectory: templatesDirectory)
        let templateExecutor = TemplateExecutor(
            actionRegistry: ActionRegistry.shared,
            eventBus: .shared
        )
        ts.setExecutor(templateExecutor)
        self.templateService = ts
        await runtime.register(service: ts as TemplateService)

        // Register terminal service (ARO-0052)
        #if !os(Windows)
        if isatty(STDOUT_FILENO) != 0 {
            let terminalService = TerminalService()
            await runtime.register(service: terminalService)
        }
        #else
        // Windows: only register if Windows Terminal
        if ProcessInfo.processInfo.environment["WT_SESSION"] != nil {
            let terminalService = TerminalService()
            await runtime.register(service: terminalService)
        }
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

        for (_, source) in sources {
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
    public func register<S: Sendable>(service: S) async {
        await runtime.register(service: service)
    }

    // MARK: - Execution

    /// Run the application
    /// - Returns: The response from the entry point
    @discardableResult
    public func run() async throws -> Response {
        // Register services (deferred from init to async context)
        await registerDefaultServices()

        // Merge all programs
        guard let mainProgram = mergedProgram() else {
            throw ApplicationError.noPrograms
        }

        // Set up HTTP request handler if OpenAPI contract exists
        setupHTTPRequestHandler(for: mainProgram)

        // Handle event replay before running application
        if let replayPath {
            try await replayEvents(from: replayPath)
        }

        // Start event recording if requested
        if recordPath != nil {
            await eventRecorder.startRecording()
        }

        // Run the application
        let response: Response
        do {
            response = try await runtime.run(mainProgram, entryPoint: entryPoint)
        } catch {
            // Stop recording and save even if execution fails
            if let recordPath {
                try await saveRecording(to: recordPath)
            }
            throw error
        }

        // Stop recording and save if requested
        if let recordPath {
            try await saveRecording(to: recordPath)
        }

        return response
    }

    /// Run and keep the application alive (for servers)
    public func runForever() async throws {
        // Register services (deferred from init to async context)
        await registerDefaultServices()

        guard let mainProgram = mergedProgram() else {
            throw ApplicationError.noPrograms
        }

        // Set up HTTP request handler if OpenAPI contract exists
        setupHTTPRequestHandler(for: mainProgram)

        // Handle event replay before running application
        if let replayPath {
            try await replayEvents(from: replayPath)
        }

        // Start event recording if requested
        if recordPath != nil {
            await eventRecorder.startRecording()
        }

        // Run the application with keepalive
        do {
            try await runtime.runAndKeepAlive(mainProgram, entryPoint: entryPoint)
        } catch {
            // Stop recording and save even if execution fails
            if let recordPath {
                try await saveRecording(to: recordPath)
            }
            throw error
        }

        // Stop recording and save if requested
        if let recordPath {
            try await saveRecording(to: recordPath)
        }
    }

    /// Stop the application
    public func stop() {
        runtime.stop()
    }

    /// Set up the HTTP request handler for routing requests to feature sets
    private func setupHTTPRequestHandler(for program: AnalyzedProgram) {
        guard let routeRegistry = routeRegistry,
              let httpServer = httpServer else {
            return // No OpenAPI contract or HTTP server
        }

        // Create a request handler that routes to feature sets
        let handler: HTTPRequestHandler = { [weak self] request in
            guard let self = self else {
                return HTTPResponse.serverError
            }

            // Match the request to an operation
            guard let match = routeRegistry.match(method: request.method, path: request.path) else {
                return HTTPResponse(
                    statusCode: 404,
                    headers: ["Content-Type": "application/json"],
                    body: "{\"error\":\"Not Found\",\"path\":\"\(request.path)\"}".data(using: .utf8)
                )
            }

            // Find the feature set by operationId
            guard let featureSet = program.featureSets.first(where: {
                $0.featureSet.name == match.operationId
            }) else {
                return HTTPResponse(
                    statusCode: 501,
                    headers: ["Content-Type": "application/json"],
                    body: "{\"error\":\"Not Implemented\",\"operationId\":\"\(match.operationId)\"}".data(using: .utf8)
                )
            }

            // Execute the feature set
            do {
                let response = try await self.executeFeatureSet(featureSet, request: request, pathParams: match.pathParameters)
                return self.convertToHTTPResponse(response, requestPath: request.path)
            } catch let templateError as TemplateError {
                // Handle template errors with appropriate HTTP status codes
                switch templateError {
                case .notFound:
                    return HTTPResponse(
                        statusCode: 404,
                        headers: ["Content-Type": "application/json"],
                        body: "{\"error\":\"Not Found\",\"message\":\"\(templateError.errorDescription ?? "Template not found")\"}".data(using: .utf8)
                    )
                default:
                    return HTTPResponse(
                        statusCode: 500,
                        headers: ["Content-Type": "application/json"],
                        body: "{\"error\":\"\(String(describing: templateError).replacingOccurrences(of: "\"", with: "\\\""))\"}".data(using: .utf8)
                    )
                }
            } catch {
                return HTTPResponse(
                    statusCode: 500,
                    headers: ["Content-Type": "application/json"],
                    body: "{\"error\":\"\(String(describing: error).replacingOccurrences(of: "\"", with: "\\\""))\"}".data(using: .utf8)
                )
            }
        }

        httpServer.setRequestHandler(handler)
        // Note: Removed verbose logging for consistency between interpreter and binary modes
    }

    /// Execute a feature set for an HTTP request
    private func executeFeatureSet(
        _ analyzedFeatureSet: AnalyzedFeatureSet,
        request: HTTPRequest,
        pathParams: [String: String]
    ) async throws -> Response {
        // Create execution context for this request
        let context = RuntimeContext(
            featureSetName: analyzedFeatureSet.featureSet.name,
            businessActivity: analyzedFeatureSet.featureSet.businessActivity,
            eventBus: .shared
        )

        // Register repository storage service for persistent in-memory storage
        context.register(InMemoryRepositoryStorage.shared as RepositoryStorageService)

        // Register WebSocket server service for broadcast support (if configured)
        #if !os(Windows)
        if let wsServer = self.httpServer?.getWebSocketServer() {
            context.register(wsServer as WebSocketServerService)
        }
        #endif

        // Register template service for HTML template rendering (ARO-0050)
        if let ts = self.templateService {
            context.register(ts as TemplateService)
        }

        // Parse JSON body if present
        var bodyValue: any Sendable = request.bodyString ?? ""
        if let body = request.body,
           let contentType = request.headers["Content-Type"],
           contentType.contains("application/json") {
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                // Convert to Sendable dictionary
                var sendableDict: [String: any Sendable] = [:]
                for (key, value) in json {
                    sendableDict[key] = convertJSONValueToSendable(value)
                }
                bodyValue = sendableDict
            }
        }

        // Bind request data to context
        context.bind("request", value: [
            "method": request.method,
            "path": request.path,
            "headers": request.headers,
            "body": bodyValue,
            "queryParameters": request.queryParameters
        ] as [String: any Sendable])

        // Bind path parameters
        context.bind("pathParameters", value: pathParams)

        // Bind query parameters
        context.bind("queryParameters", value: request.queryParameters)

        // Also bind body directly for convenience
        if let parsedBody = bodyValue as? [String: any Sendable] {
            context.bind("body", value: parsedBody)
        }

        // Create executor and run with shared global symbols
        let executor = FeatureSetExecutor(
            actionRegistry: .shared,
            eventBus: .shared,
            globalSymbols: await runtime.globalSymbols
        )

        return try await executor.execute(analyzedFeatureSet, context: context)
    }

    /// Convert ARO Response to HTTP Response
    private func convertToHTTPResponse(_ response: Response, requestPath: String = "") -> HTTPResponse {
        // Map status string to HTTP status code
        let statusCode = mapStatusToHTTPCode(response.status)

        // Check for MIME type from file extension in request path
        if let mimeType = mimeTypeFromPath(requestPath), response.data.count == 1 {
            // Try to get the content as a String
            if let anySendable = response.data.values.first,
               let content: String = anySendable.get() {
                return HTTPResponse(
                    statusCode: statusCode,
                    headers: ["Content-Type": mimeType],
                    body: content.data(using: .utf8)
                )
            }
        }

        // Check if response data contains HTML content
        // If so, return it directly with text/html content type
        if let htmlValue = detectHTMLContent(in: response.data) {
            return HTTPResponse(
                statusCode: statusCode,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: htmlValue.data(using: .utf8)
            )
        }

        // Check if response data contains raw CSS/JS content
        if let (rawContent, contentType) = detectRawContent(in: response.data) {
            return HTTPResponse(
                statusCode: statusCode,
                headers: ["Content-Type": contentType],
                body: rawContent.data(using: .utf8)
            )
        }

        // Default: JSON response
        let headers = ["Content-Type": "application/json"]

        // Build JSON response body from Response.data
        var jsonBody: [String: Any] = [:]

        // Include response data - convert AnySendable values to regular values
        for (key, anySendable) in response.data {
            if let str: String = anySendable.get() {
                // Check if the string is JSON - if so, parse it as a nested object
                if (str.hasPrefix("{") || str.hasPrefix("[")) {
                    if let jsonData = str.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: jsonData) {
                        jsonBody[key] = parsed
                    } else {
                        jsonBody[key] = str
                    }
                } else {
                    jsonBody[key] = str
                }
            } else if let int: Int = anySendable.get() {
                jsonBody[key] = int
            } else if let double: Double = anySendable.get() {
                jsonBody[key] = double
            } else if let bool: Bool = anySendable.get() {
                jsonBody[key] = bool
            } else {
                // Fallback: stringify
                jsonBody[key] = String(describing: anySendable)
            }
        }

        // If no data, include status info
        if jsonBody.isEmpty {
            jsonBody["status"] = response.status
            if !response.reason.isEmpty {
                jsonBody["reason"] = response.reason
            }
        }

        let bodyData: Data?
        if let jsonData = try? JSONSerialization.data(withJSONObject: jsonBody, options: [.sortedKeys]) {
            bodyData = jsonData
        } else {
            bodyData = "{\"status\":\"\(response.status)\"}".data(using: .utf8)
        }

        return HTTPResponse(
            statusCode: statusCode,
            headers: headers,
            body: bodyData
        )
    }

    /// Detect if response data contains HTML content (single string value starting with HTML markers)
    private func detectHTMLContent(in data: [String: AnySendable]) -> String? {
        // If there's exactly one value and it's an HTML string, return it
        guard data.count == 1 else { return nil }

        for (_, anySendable) in data {
            if let str: String = anySendable.get() {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("<!DOCTYPE") ||
                   trimmed.hasPrefix("<!doctype") ||
                   trimmed.hasPrefix("<html") ||
                   trimmed.hasPrefix("<HTML") {
                    return str
                }
            }
        }
        return nil
    }

    /// Detect if response data contains raw text content that should be returned as-is
    /// Returns (content, contentType) tuple or nil if not detected
    private func detectRawContent(in data: [String: AnySendable]) -> (String, String)? {
        guard data.count == 1 else { return nil }

        for (_, anySendable) in data {
            if let str: String = anySendable.get() {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)

                // Strip CSS/JS block comments for content detection
                var contentForDetection = trimmed
                if trimmed.hasPrefix("/*") {
                    // Find end of block comment and check what follows
                    if let endRange = trimmed.range(of: "*/") {
                        let afterComment = String(trimmed[endRange.upperBound...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        contentForDetection = afterComment
                    }
                }

                // Detect CSS first: starts with selector patterns
                // CSS selectors: :root, element, .class, #id, @media, @keyframes, *, etc.
                if !contentForDetection.hasPrefix("{") && !contentForDetection.hasPrefix("<") {
                    let cssPattern = try? NSRegularExpression(
                        pattern: "^(:|@|\\*|[a-zA-Z][a-zA-Z0-9-]*|\\.[a-zA-Z]|#[a-zA-Z])[^{]*\\{",
                        options: []
                    )
                    if let match = cssPattern?.firstMatch(in: contentForDetection, range: NSRange(contentForDetection.startIndex..., in: contentForDetection)),
                       match.range.location != NSNotFound {
                        return (str, "text/css; charset=utf-8")
                    }
                }

                // Detect Prometheus text exposition format (ARO-0044)
                // Prometheus output starts with "# HELP" or "# TYPE" comment lines
                if trimmed.hasPrefix("# HELP ") || trimmed.hasPrefix("# TYPE ") {
                    return (str, "text/plain; version=0.0.4; charset=utf-8")
                }

                // Detect JavaScript patterns
                if trimmed.hasPrefix("var ") || trimmed.hasPrefix("let ") ||
                   trimmed.hasPrefix("const ") || trimmed.hasPrefix("function ") ||
                   trimmed.hasPrefix("//") ||
                   trimmed.hasPrefix("'use strict'") || trimmed.hasPrefix("\"use strict\"") ||
                   trimmed.hasPrefix("(function") || trimmed.hasPrefix("import ") ||
                   trimmed.hasPrefix("export ") {
                    return (str, "text/javascript; charset=utf-8")
                }

                // Check content after block comment for JS patterns
                if trimmed.hasPrefix("/*") && !contentForDetection.isEmpty {
                    if contentForDetection.hasPrefix("var ") || contentForDetection.hasPrefix("let ") ||
                       contentForDetection.hasPrefix("const ") || contentForDetection.hasPrefix("function ") ||
                       contentForDetection.hasPrefix("(function") {
                        return (str, "text/javascript; charset=utf-8")
                    }
                }
            }
        }
        return nil
    }

    /// Detect MIME type from file extension in request path
    private func mimeTypeFromPath(_ path: String) -> String? {
        let lowercasePath = path.lowercased()

        // Common web file extensions
        if lowercasePath.hasSuffix(".css") {
            return "text/css; charset=utf-8"
        } else if lowercasePath.hasSuffix(".js") {
            return "text/javascript; charset=utf-8"
        } else if lowercasePath.hasSuffix(".json") {
            return "application/json; charset=utf-8"
        } else if lowercasePath.hasSuffix(".html") || lowercasePath.hasSuffix(".htm") {
            return "text/html; charset=utf-8"
        } else if lowercasePath.hasSuffix(".xml") {
            return "application/xml; charset=utf-8"
        } else if lowercasePath.hasSuffix(".txt") {
            return "text/plain; charset=utf-8"
        } else if lowercasePath.hasSuffix(".svg") {
            return "image/svg+xml"
        } else if lowercasePath.hasSuffix(".png") {
            return "image/png"
        } else if lowercasePath.hasSuffix(".jpg") || lowercasePath.hasSuffix(".jpeg") {
            return "image/jpeg"
        } else if lowercasePath.hasSuffix(".gif") {
            return "image/gif"
        } else if lowercasePath.hasSuffix(".webp") {
            return "image/webp"
        } else if lowercasePath.hasSuffix(".ico") {
            return "image/x-icon"
        } else if lowercasePath.hasSuffix(".woff") {
            return "font/woff"
        } else if lowercasePath.hasSuffix(".woff2") {
            return "font/woff2"
        } else if lowercasePath.hasSuffix(".ttf") {
            return "font/ttf"
        } else if lowercasePath.hasSuffix(".eot") {
            return "application/vnd.ms-fontobject"
        }

        return nil
    }

    /// Map ARO status string to HTTP status code
    private func mapStatusToHTTPCode(_ status: String) -> Int {
        switch status.lowercased() {
        case "ok", "success":
            return 200
        case "created":
            return 201
        case "accepted":
            return 202
        case "nocontent", "no-content":
            return 204
        case "badrequest", "bad-request", "invalid":
            return 400
        case "unauthorized":
            return 401
        case "forbidden":
            return 403
        case "notfound", "not-found":
            return 404
        case "conflict":
            return 409
        case "error", "servererror", "server-error":
            return 500
        default:
            return 200
        }
    }

    // MARK: - Private

    /// Convert a JSON value (Any) to Sendable, recursively handling nested structures
    private func convertJSONValueToSendable(_ value: Any) -> any Sendable {
        if let str = value as? String { return str }
        if let num = value as? Int { return num }
        if let num = value as? Double { return num }
        if let bool = value as? Bool { return bool }
        if let array = value as? [Any] {
            return array.map { convertJSONValueToSendable($0) }
        }
        if let dict = value as? [String: Any] {
            var result: [String: any Sendable] = [:]
            for (k, v) in dict {
                result[k] = convertJSONValueToSendable(v)
            }
            return result
        }
        return String(describing: value)
    }

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
            for (_, info) in program.globalRegistry.allPublished {
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

    // MARK: - Event Recording and Replay

    /// Replay events from a JSON file
    private func replayEvents(from path: String) async throws {
        let replayer = EventReplayer(eventBus: .shared)
        let recording = try await replayer.loadFromFile(path)

        if config.verbose {
            print("Replaying \(recording.events.count) events from \(path)")
            print("Recording: \(recording.application)")
            print("Recorded at: \(recording.recorded)")
            print()
        }

        // Replay events without timing delays (fast replay)
        await replayer.replayFast(recording)

        if config.verbose {
            print("Event replay completed")
            print()
        }
    }

    /// Save recorded events to a JSON file
    private func saveRecording(to path: String) async throws {
        let events = await eventRecorder.stopRecording()

        if config.verbose {
            print("\nRecorded \(events.count) events")
            print("Saving to: \(path)")
        }

        try await eventRecorder.saveToFile(path, applicationName: "ARO Application")

        if config.verbose {
            print("Events saved successfully")
        }
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
            importPaths: [],  // Basic discover doesn't resolve imports
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

    private func findSourceFiles(in directory: URL, includePlugins: Bool = false) throws -> [URL] {
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
            // Skip files in Plugins/ directory unless includePlugins is true
            // For interpreter: Plugins are loaded separately by UnifiedPluginLoader
            // For compiler: Plugins need to be compiled into the binary
            if !includePlugins {
                let relativePath = fileURL.path.replacingOccurrences(of: directory.path, with: "")
                if relativePath.hasPrefix("/Plugins/") || relativePath.contains("/Plugins/") {
                    continue
                }
            }

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

    /// All source files found (including from imported applications)
    public let sourceFiles: [URL]

    /// Import paths discovered (ARO-0007)
    public let importPaths: [String]

    /// The entry point feature set name
    public let entryPointFeatureSet: String

    /// OpenAPI specification (if contract exists)
    public let openAPISpec: OpenAPISpec?

    /// Whether an OpenAPI contract was found
    public let hasOpenAPIContract: Bool
}

// MARK: - Import Resolution (ARO-0007)

extension ApplicationDiscovery {
    /// Resolve imports from source files
    /// - Parameters:
    ///   - sourceFiles: The source files to parse for imports
    ///   - rootPath: The root directory for resolving relative paths
    /// - Returns: List of resolved import paths
    public func resolveImports(from sourceFiles: [URL], rootPath: URL) throws -> [URL] {
        var importedPaths: Set<URL> = []
        let compiler = Compiler()

        for sourceFile in sourceFiles {
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            let result = compiler.compile(source)

            // Extract imports from parsed program
            for importDecl in result.analyzedProgram.program.imports {
                let resolvedPath = resolveImportPath(importDecl.path, relativeTo: rootPath)
                importedPaths.insert(resolvedPath)
            }
        }

        return Array(importedPaths)
    }

    /// Resolve an import path relative to a base directory
    private func resolveImportPath(_ importPath: String, relativeTo baseDir: URL) -> URL {
        // Use absoluteURL.standardized to correctly resolve relative paths
        // when baseDir itself is a relative URL (e.g., ".")
        // Handle relative paths like ../user-service, ./utils
        // Use absoluteURL.standardized to properly resolve relative base directories (e.g., ".")
        if importPath.hasPrefix("../") || importPath.hasPrefix("./") {
            return baseDir.appendingPathComponent(importPath).absoluteURL.standardized
        }
        // Treat as relative to base directory
        return baseDir.appendingPathComponent(importPath).absoluteURL.standardized
    }

    /// Discover an application with all its imports (recursive)
    /// - Parameters:
    ///   - path: Directory or file path
    ///   - entryPoint: Entry point feature set name
    ///   - visited: Already visited paths (to prevent cycles)
    ///   - includePlugins: Whether to include plugin .aro files (true for compilation, false for interpretation)
    /// - Returns: Application configuration with all imported sources
    public func discoverWithImports(
        at path: URL,
        entryPoint: String = "Application-Start",
        visited: Set<URL> = [],
        includePlugins: Bool = false
    ) async throws -> DiscoveredApplication {
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
            throw ApplicationError.sourceFileNotFound(path.path)
        }

        let sourceFiles: [URL]
        let rootPath: URL

        if isDirectory.boolValue {
            sourceFiles = try findSourceFiles(in: path, includePlugins: includePlugins)
            rootPath = path
        } else {
            sourceFiles = [path]
            rootPath = path.deletingLastPathComponent()
        }

        // Prevent cycles
        let standardizedRoot = rootPath.standardized
        var newVisited = visited
        newVisited.insert(standardizedRoot)

        // Resolve imports from source files
        let importedPaths = try resolveImports(from: sourceFiles, rootPath: rootPath)
        var allSourceFiles = sourceFiles
        var allImportPaths: [String] = []

        // Recursively discover imported applications
        for importedPath in importedPaths {
            let standardizedImport = importedPath.standardized
            if newVisited.contains(standardizedImport) {
                // Skip circular imports
                continue
            }

            if FileManager.default.fileExists(atPath: importedPath.path) {
                let importedApp = try await discoverWithImports(
                    at: importedPath,
                    entryPoint: entryPoint,
                    visited: newVisited,
                    includePlugins: includePlugins
                )
                allSourceFiles.append(contentsOf: importedApp.sourceFiles)
                allImportPaths.append(importedPath.path)
            }
        }

        // Check for OpenAPI contract
        let openAPISpec = try loadOpenAPISpec(from: rootPath)

        return DiscoveredApplication(
            rootPath: rootPath,
            sourceFiles: allSourceFiles,
            importPaths: allImportPaths,
            entryPointFeatureSet: entryPoint,
            openAPISpec: openAPISpec,
            hasOpenAPIContract: openAPISpec != nil
        )
    }
}
