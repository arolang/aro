// ============================================================
// RuntimeContext.swift
// ARO Runtime - Concrete Execution Context Implementation
// ============================================================

import Foundation
import AROParser

/// Concrete implementation of ExecutionContext
///
/// RuntimeContext provides thread-safe variable storage and service access
/// for executing ARO feature sets.
public final class RuntimeContext: ExecutionContext, @unchecked Sendable {
    // MARK: - Properties

    /// Thread-safe lock for all mutable state
    private let lock = NSLock()

    /// Variable storage (now using TypedValue for type preservation)
    private var variables: [String: TypedValue] = [:]

    /// Track which variables are user-defined (immutable) vs framework-internal (mutable)
    /// Only user variables enforce immutability; framework variables can be rebound
    private var immutableVariables: Set<String> = []

    /// Service registry
    private var services: [ObjectIdentifier: any Sendable] = [:]

    /// Repository registry
    private var repositories: [String: Any] = [:]

    /// Current response
    private var _response: Response?

    /// Error tracking for binary mode
    private var _executionError: Error?

    /// Event bus for event emission
    public let eventBus: EventBus?

    /// Wait state flag
    private var _isWaiting: Bool = false

    /// Continuation for wait/shutdown signaling
    private var shutdownContinuation: CheckedContinuation<Void, Error>?

    /// Output context for formatting
    private let _outputContext: OutputContext

    /// Whether this is a compiled binary execution
    private let _isCompiled: Bool

    // MARK: - Metadata

    public let featureSetName: String
    public let businessActivity: String
    public let executionId: String
    public let parent: ExecutionContext?

    // MARK: - Initialization

    /// Initialize a new runtime context
    /// - Parameters:
    ///   - featureSetName: Name of the feature set being executed
    ///   - businessActivity: Business activity this feature set belongs to
    ///   - outputContext: Output context for formatting (defaults to .human)
    ///   - eventBus: Optional event bus for event emission
    ///   - parent: Optional parent context for nested execution
    ///   - isCompiled: Whether this is a compiled binary execution (defaults to false)
    public init(
        featureSetName: String,
        businessActivity: String = "",
        outputContext: OutputContext = .human,
        eventBus: EventBus? = nil,
        parent: ExecutionContext? = nil,
        isCompiled: Bool = false
    ) {
        self.featureSetName = featureSetName
        self.businessActivity = businessActivity
        self.executionId = UUID().uuidString
        self._outputContext = outputContext
        self.eventBus = eventBus
        self.parent = parent
        self._isCompiled = isCompiled
    }

    // MARK: - Variable Management

    public func resolve<T: Sendable>(_ name: String) -> T? {
        lock.lock()
        defer { lock.unlock() }

        if let typedValue = variables[name], let value = typedValue.value as? T {
            return value
        }
        // Try parent context
        return parent?.resolve(name)
    }

    public func resolveAny(_ name: String) -> (any Sendable)? {
        lock.lock()
        defer { lock.unlock() }

        // Magic variable: <now> returns current date/time
        if name == "now" {
            let dateService = services[ObjectIdentifier(DateService.self)] as? DateService ?? DefaultDateService()
            return dateService.now(timezone: nil)
        }

        // Magic variable: <Contract> returns OpenAPI contract metadata
        if name == "Contract" {
            return buildContractObject()
        }

        // Magic variable: <http-server> returns Contract.http-server
        // This allows both <Contract> and <http-server> to work
        if name == "http-server" || name == "httpServer" {
            return buildContractObject()?.httpServer
        }

        // Magic variable: <metrics> returns current execution metrics
        if name == "metrics" {
            return MetricsCollector.shared.snapshot()
        }

        if let typedValue = variables[name] {
            return typedValue.value
        }
        // Try parent context
        return parent?.resolveAny(name)
    }

    /// Resolve a variable returning the full TypedValue (type + value)
    public func resolveTyped(_ name: String) -> TypedValue? {
        lock.lock()
        defer { lock.unlock() }

        if let typedValue = variables[name] {
            return typedValue
        }
        // Try parent context (if it's a RuntimeContext)
        if let parentRuntime = parent as? RuntimeContext {
            return parentRuntime.resolveTyped(name)
        }
        // Fall back to resolveAny and wrap with unknown type
        if let value = parent?.resolveAny(name) {
            return TypedValue(value, type: .unknown)
        }
        return nil
    }

    /// Get the type of a variable without retrieving its value
    public func typeOf(_ name: String) -> DataType? {
        lock.lock()
        defer { lock.unlock() }

        if let typedValue = variables[name] {
            return typedValue.type
        }
        // Try parent context
        if let parentRuntime = parent as? RuntimeContext {
            return parentRuntime.typeOf(name)
        }
        return nil
    }

    /// Build the Contract magic object from OpenAPI spec service
    private func buildContractObject() -> Contract? {
        guard let specService = services[ObjectIdentifier(OpenAPISpecService.self)] as? OpenAPISpecService else {
            return nil
        }

        // Extract server configuration from OpenAPI spec
        let port = specService.serverPort ?? 8080
        let hostname = specService.serverHost ?? "0.0.0.0"
        let routes = specService.spec.paths.map { $0.key }
        let routeCount = routes.count

        let httpServer = HTTPServerConfig(
            port: port,
            hostname: hostname,
            routes: routes,
            routeCount: routeCount
        )

        return Contract(httpServer: httpServer)
    }

    public func bind(_ name: String, value: any Sendable) {
        bind(name, value: value, allowRebind: false)
    }

    public func bind(_ name: String, value: any Sendable, allowRebind: Bool) {
        // Auto-wrap with inferred type
        let typedValue: TypedValue
        if let tv = value as? TypedValue {
            typedValue = tv
        } else {
            typedValue = TypedValue.infer(value)
        }
        bindTyped(name, value: typedValue, allowRebind: allowRebind)
    }

    /// Bind a variable with explicit type information
    public func bindTyped(_ name: String, value: TypedValue) {
        bindTyped(name, value: value, allowRebind: false)
    }

    /// Bind a variable with explicit type information and rebind option
    public func bindTyped(_ name: String, value: TypedValue, allowRebind: Bool) {
        lock.lock()
        defer { lock.unlock() }

        // Check immutability: framework variables (_prefix) can be rebound
        let isFrameworkVariable = name.hasPrefix("_")

        if !isFrameworkVariable && !allowRebind && immutableVariables.contains(name) {
            // Don't manually unlock - defer handles cleanup (though fatalError terminates)
            fatalError("""
                Runtime Error: Cannot rebind immutable variable '\(name)'
                Feature: \(featureSetName)
                Business Activity: \(businessActivity)

                Variables in ARO are immutable. Once bound, they cannot be changed.
                Create a new variable instead: <Action> the <\(name)-updated> ...

                This error indicates the semantic analyzer missed a duplicate binding.
                Please report this as a compiler bug.
                """)
        }

        variables[name] = value

        // Mark user variables as immutable (framework variables stay mutable)
        if !isFrameworkVariable {
            immutableVariables.insert(name)
        }
    }

    public func unbind(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        variables.removeValue(forKey: name)
        immutableVariables.remove(name)
    }

    public func exists(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return variables[name] != nil || (parent?.exists(name) ?? false)
    }

    public var variableNames: Set<String> {
        lock.lock()
        defer { lock.unlock() }

        var names = Set(variables.keys)
        if let parentNames = parent?.variableNames {
            names.formUnion(parentNames)
        }
        return names
    }

    // MARK: - Service Access

    public func service<S>(_ type: S.Type) -> S? {
        lock.lock()
        defer { lock.unlock() }

        let id = ObjectIdentifier(type)
        if let service = services[id] as? S {
            return service
        }
        // Try parent context
        return parent?.service(type)
    }

    public func register<S: Sendable>(_ service: S) {
        lock.lock()
        defer { lock.unlock() }
        services[ObjectIdentifier(S.self)] = service
    }

    /// Register a service with an explicit type ID (for preserving type info across type-erased collections)
    public func registerWithTypeId(_ typeId: ObjectIdentifier, service: any Sendable) {
        lock.lock()
        defer { lock.unlock() }
        services[typeId] = service
    }

    // MARK: - Repository Access

    public func repository<T: Sendable>(named name: String) -> (any Repository<T>)? {
        lock.lock()
        defer { lock.unlock() }

        if let repo = repositories[name] as? any Repository<T> {
            return repo
        }
        // Try parent context
        return parent?.repository(named: name)
    }

    public func registerRepository<T: Sendable>(name: String, repository: any Repository<T>) {
        lock.lock()
        defer { lock.unlock() }
        repositories[name] = repository
    }

    // MARK: - Response Management

    public func setResponse(_ response: Response) {
        lock.lock()
        defer { lock.unlock() }
        _response = response
    }

    public func getResponse() -> Response? {
        lock.lock()
        defer { lock.unlock() }
        return _response
    }

    // MARK: - Error Management (for binary mode)

    /// Set an execution error (e.g., from action failures)
    public func setExecutionError(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if _executionError == nil {
            _executionError = error
        }
    }

    /// Get the execution error if one occurred
    public func getExecutionError() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return _executionError
    }

    /// Check if an execution error occurred
    public func hasExecutionError() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _executionError != nil
    }

    // MARK: - Event Emission

    public func emit(_ event: any RuntimeEvent) {
        eventBus?.publish(event)
    }

    // MARK: - Child Context

    public func createChild(featureSetName: String) -> ExecutionContext {
        RuntimeContext(
            featureSetName: featureSetName,
            businessActivity: businessActivity,
            outputContext: _outputContext,
            eventBus: eventBus,
            parent: self,
            isCompiled: _isCompiled
        )
    }

    /// Create a child context with a different business activity
    public func createChild(featureSetName: String, businessActivity: String) -> ExecutionContext {
        RuntimeContext(
            featureSetName: featureSetName,
            businessActivity: businessActivity,
            outputContext: _outputContext,
            eventBus: eventBus,
            parent: self,
            isCompiled: _isCompiled
        )
    }

    // MARK: - Wait State Management

    public func enterWaitState() {
        lock.lock()
        defer { lock.unlock() }
        _isWaiting = true
    }

    public func waitForShutdown() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            shutdownContinuation = continuation
            lock.unlock()
        }
    }

    public var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isWaiting
    }

    public func signalShutdown() {
        lock.lock()
        let continuation = shutdownContinuation
        shutdownContinuation = nil
        _isWaiting = false
        lock.unlock()

        continuation?.resume(returning: ())
    }

    // MARK: - Output Context

    public var outputContext: OutputContext {
        _outputContext
    }

    public var isDebugMode: Bool {
        _outputContext == .developer
    }

    public var isTestMode: Bool {
        _outputContext == .developer
    }

    public var isCompiled: Bool {
        _isCompiled
    }
}

// MARK: - Convenience Extensions

extension RuntimeContext {
    /// Bind multiple values at once (auto-infers types)
    /// - Parameter bindings: Dictionary of name-value pairs
    public func bindAll(_ bindings: [String: any Sendable]) {
        for (name, value) in bindings {
            bind(name, value: value)
        }
    }

    /// Bind multiple typed values at once
    /// - Parameter bindings: Dictionary of name-TypedValue pairs
    public func bindAllTyped(_ bindings: [String: TypedValue]) {
        for (name, value) in bindings {
            bindTyped(name, value: value)
        }
    }

    /// Create a context with initial bindings
    /// - Parameters:
    ///   - featureSetName: Name of the feature set
    ///   - businessActivity: Business activity this feature set belongs to
    ///   - outputContext: Output context for formatting
    ///   - eventBus: Optional event bus
    ///   - initialBindings: Initial variable bindings
    /// - Returns: A new context with the bindings
    public static func with(
        featureSetName: String,
        businessActivity: String = "",
        outputContext: OutputContext = .human,
        eventBus: EventBus? = nil,
        initialBindings: [String: any Sendable]
    ) -> RuntimeContext {
        let context = RuntimeContext(
            featureSetName: featureSetName,
            businessActivity: businessActivity,
            outputContext: outputContext,
            eventBus: eventBus
        )
        context.bindAll(initialBindings)
        return context
    }
}
