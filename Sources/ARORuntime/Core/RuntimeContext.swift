// ============================================================
// RuntimeContext.swift
// ARO Runtime - Concrete Execution Context Implementation
// ============================================================

import Foundation
import AROParser

/// Concrete implementation of ExecutionContext
///
/// RuntimeContext is an actor, so its internal serial executor replaces the
/// old NSLock. All protocol methods are `nonisolated` so they can be called
/// synchronously from outside the actor context; they access storage marked
/// `nonisolated(unsafe)` — safe because a single FeatureSetExecutor drives
/// one RuntimeContext serially, never concurrently.
public actor RuntimeContext: ExecutionContext {
    // MARK: - Properties

    /// Variable storage (now using TypedValue for type preservation)
    nonisolated(unsafe) private var variables: [String: TypedValue] = [:]

    /// Track which variables are user-defined (immutable) vs framework-internal (mutable)
    /// Only user variables enforce immutability; framework variables can be rebound
    nonisolated(unsafe) private var immutableVariables: Set<String> = []

    /// Service registry
    nonisolated(unsafe) private var services: [ObjectIdentifier: any Sendable] = [:]

    /// Repository registry
    nonisolated(unsafe) private var repositories: [String: Any] = [:]

    /// Current response
    nonisolated(unsafe) private var _response: Response?

    /// Error tracking for binary mode
    nonisolated(unsafe) private var _executionError: Error?

    /// DI container providing shared infrastructure services
    public nonisolated let container: RuntimeContainer

    /// Event bus for event emission
    public nonisolated let eventBus: EventBus?

    /// Wait state flag
    nonisolated(unsafe) private var _isWaiting: Bool = false

    /// Continuation for wait/shutdown signaling
    nonisolated(unsafe) private var shutdownContinuation: CheckedContinuation<Void, Error>?

    /// Output context for formatting
    private nonisolated let _outputContext: OutputContext

    /// Whether this is a compiled binary execution
    private nonisolated let _isCompiled: Bool

    /// Phase 2 async driver channel — set once at context init time by
    /// AROCContextHandle for compiled binary feature sets.  When non-nil,
    /// ActionRunner.executeSyncWithResult submits work here instead of
    /// spawning a new Task.detached per action call.
    public nonisolated let driverChannel: ActionDriverChannel?

    /// Template output buffer (ARO-0050)
    nonisolated(unsafe) private var _templateBuffer: String = ""

    /// Whether this is a template rendering context
    private nonisolated let _isTemplateContext: Bool

    /// Schema registry for typed event extraction (ARO-0046)
    nonisolated(unsafe) private var _schemaRegistry: SchemaRegistry?

    /// Mutable scope depth for while loops (ARO-0131)
    /// When > 0, all bind calls automatically allow rebinding
    nonisolated(unsafe) private var mutableScopeDepth: Int = 0

    // MARK: - Metadata

    public nonisolated let featureSetName: String
    public nonisolated let businessActivity: String
    public nonisolated let executionId: String
    public nonisolated let parent: ExecutionContext?

    // MARK: - Initialization

    /// Initialize a new runtime context
    /// - Parameters:
    ///   - featureSetName: Name of the feature set being executed
    ///   - businessActivity: Business activity this feature set belongs to
    ///   - outputContext: Output context for formatting (defaults to .human)
    ///   - eventBus: Optional event bus for event emission (overrides container.eventBus when provided)
    ///   - container: DI container providing shared services (defaults to `.default`)
    ///   - parent: Optional parent context for nested execution
    ///   - isCompiled: Whether this is a compiled binary execution (defaults to false)
    ///   - isTemplateContext: Whether this is a template rendering context (defaults to false)
    public init(
        featureSetName: String,
        businessActivity: String = "",
        outputContext: OutputContext = .human,
        eventBus: EventBus? = nil,
        container: RuntimeContainer? = nil,
        parent: ExecutionContext? = nil,
        isCompiled: Bool = false,
        isTemplateContext: Bool = false,
        driverChannel: ActionDriverChannel? = nil
    ) {
        self.featureSetName = featureSetName
        self.businessActivity = businessActivity
        self.executionId = UUID().uuidString
        self._outputContext = outputContext
        self._isCompiled = isCompiled
        self._isTemplateContext = isTemplateContext
        self.driverChannel = driverChannel
        self.parent = parent

        // Container resolution order: explicit > inherit from parent > global default
        let resolvedContainer: RuntimeContainer
        if let c = container {
            resolvedContainer = c
        } else if let parentCtx = parent as? RuntimeContext {
            resolvedContainer = parentCtx.container
        } else {
            resolvedContainer = .default
        }
        self.container = resolvedContainer

        // EventBus resolution order: explicit > container
        self.eventBus = eventBus ?? resolvedContainer.eventBus
    }

    // MARK: - Variable Management

    public nonisolated func resolve<T: Sendable>(_ name: String) -> T? {
        if let typedValue = variables[name], let value = typedValue.value as? T {
            return value
        }
        // Try parent context
        return parent?.resolve(name)
    }

    public nonisolated func resolveAny(_ name: String) -> (any Sendable)? {
        // Magic variable: <now> returns current date/time
        if name == "now" {
            let dateService = services[ObjectIdentifier(DateService.self)] as? DateService ?? DefaultDateService()
            return dateService.now(timezone: nil)
        }

        // Magic variable: <Contract> or <contract> returns OpenAPI contract metadata
        if name == "contract" || name == "Contract" {
            return buildContractObject()
        }

        // Magic variable: <http-server> returns Contract.http-server
        // This allows both <Contract> and <http-server> to work
        if name == "http-server" || name == "httpServer" {
            return buildContractObject()?.httpServer
        }

        // Magic variable: <metrics> returns current execution metrics
        if name == "metrics" {
            return container.metricsCollector.snapshot()
        }

        // Magic variable: <application> provides application context (used in Stop/Close actions)
        if name == "application" {
            return ["type": "application"] as [String: any Sendable]
        }

        if let typedValue = variables[name] {
            return typedValue.value
        }
        // Try parent context
        return parent?.resolveAny(name)
    }

    /// Resolve a variable returning the full TypedValue (type + value)
    public nonisolated func resolveTyped(_ name: String) -> TypedValue? {
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
    public nonisolated func typeOf(_ name: String) -> DataType? {
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
    private nonisolated func buildContractObject() -> Contract? {
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

    public nonisolated func bind(_ name: String, value: any Sendable) {
        bind(name, value: value, allowRebind: false)
    }

    public nonisolated func bind(_ name: String, value: any Sendable, allowRebind: Bool) {
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
    public nonisolated func bindTyped(_ name: String, value: TypedValue) {
        bindTyped(name, value: value, allowRebind: false)
    }

    /// Bind a variable with explicit type information and rebind option
    public nonisolated func bindTyped(_ name: String, value: TypedValue, allowRebind: Bool) {
        // Check immutability: framework variables (_prefix) can be rebound
        let isFrameworkVariable = name.hasPrefix("_")

        if !isFrameworkVariable && !allowRebind && mutableScopeDepth == 0 && immutableVariables.contains(name) {
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

    public nonisolated func unbind(_ name: String) {
        variables.removeValue(forKey: name)
        immutableVariables.remove(name)
    }

    /// Enter a mutable scope (e.g., while loop body). Variables can be rebound within this scope.
    public nonisolated func enterMutableScope() {
        mutableScopeDepth += 1
    }

    /// Exit a mutable scope. Restores immutability enforcement when depth reaches zero.
    public nonisolated func exitMutableScope() {
        if mutableScopeDepth > 0 { mutableScopeDepth -= 1 }
    }

    public nonisolated func exists(_ name: String) -> Bool {
        return variables[name] != nil || (parent?.exists(name) ?? false)
    }

    /// Check if a variable is bound in THIS context only (ignoring parent contexts).
    /// Used by FeatureSetExecutor to decide whether to create a local shadow binding.
    public nonisolated func existsLocally(_ name: String) -> Bool {
        return variables[name] != nil
    }

    public nonisolated var variableNames: Set<String> {
        var names = Set(variables.keys)
        if let parentNames = parent?.variableNames {
            names.formUnion(parentNames)
        }
        return names
    }

    // MARK: - Service Access

    public nonisolated func service<S>(_ type: S.Type) -> S? {
        let id = ObjectIdentifier(type)
        if let service = services[id] as? S {
            return service
        }
        // Try parent context
        return parent?.service(type)
    }

    public nonisolated func register<S: Sendable>(_ service: S) {
        services[ObjectIdentifier(S.self)] = service
    }

    /// Register a service with an explicit type ID (for preserving type info across type-erased collections)
    public nonisolated func registerWithTypeId(_ typeId: ObjectIdentifier, service: any Sendable) {
        services[typeId] = service
    }

    // MARK: - Repository Access

    public nonisolated func repository<T: Sendable>(named name: String) -> (any Repository<T>)? {
        if let repo = repositories[name] as? any Repository<T> {
            return repo
        }
        // Try parent context
        return parent?.repository(named: name)
    }

    public nonisolated func registerRepository<T: Sendable>(name: String, repository: any Repository<T>) {
        repositories[name] = repository
    }

    // MARK: - Response Management

    public nonisolated func setResponse(_ response: Response) {
        _response = response
    }

    public nonisolated func getResponse() -> Response? {
        return _response
    }

    // MARK: - Error Management (for binary mode)

    /// Set an execution error (e.g., from action failures)
    public nonisolated func setExecutionError(_ error: Error) {
        if _executionError == nil {
            _executionError = error
        }
    }

    /// Get the execution error if one occurred
    public nonisolated func getExecutionError() -> Error? {
        return _executionError
    }

    /// Check if an execution error occurred
    public nonisolated func hasExecutionError() -> Bool {
        return _executionError != nil
    }

    // MARK: - Event Emission

    public nonisolated func emit(_ event: any RuntimeEvent) {
        eventBus?.publish(event)
    }

    // MARK: - Child Context

    public nonisolated func createChild(featureSetName: String) -> ExecutionContext {
        RuntimeContext(
            featureSetName: featureSetName,
            businessActivity: businessActivity,
            outputContext: _outputContext,
            eventBus: eventBus,
            container: container,
            parent: self,
            isCompiled: _isCompiled,
            isTemplateContext: false,
            driverChannel: driverChannel
        )
    }

    /// Create a child context with a different business activity
    public nonisolated func createChild(featureSetName: String, businessActivity: String) -> ExecutionContext {
        RuntimeContext(
            featureSetName: featureSetName,
            businessActivity: businessActivity,
            outputContext: _outputContext,
            eventBus: eventBus,
            container: container,
            parent: self,
            isCompiled: _isCompiled,
            isTemplateContext: false,
            driverChannel: driverChannel
        )
    }

    /// Create a child context for template rendering (ARO-0050)
    /// This context has an isolated template buffer and copies all parent variables
    public nonisolated func createTemplateContext() -> RuntimeContext {
        let templateContext = RuntimeContext(
            featureSetName: "template:\(featureSetName)",
            businessActivity: businessActivity,
            outputContext: _outputContext,
            eventBus: eventBus,
            container: container,
            parent: self,
            isCompiled: _isCompiled,
            isTemplateContext: true
        )

        // Copy all variables from parent context for isolation
        // Changes in template context won't affect parent
        for name in variableNames {
            if let value = resolveAny(name) {
                templateContext.bind(name, value: value, allowRebind: true)
            }
        }

        // Copy services from parent
        for (typeId, service) in services {
            templateContext.registerWithTypeId(typeId, service: service)
        }

        return templateContext
    }

    // MARK: - Wait State Management

    public nonisolated func enterWaitState() {
        _isWaiting = true
    }

    public nonisolated func waitForShutdown() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            shutdownContinuation = continuation
        }
    }

    public nonisolated var isWaiting: Bool {
        return _isWaiting
    }

    public nonisolated func signalShutdown() {
        let continuation = shutdownContinuation
        shutdownContinuation = nil
        _isWaiting = false
        continuation?.resume(returning: ())
    }

    // MARK: - Output Context

    public nonisolated var outputContext: OutputContext {
        _outputContext
    }

    public nonisolated var isDebugMode: Bool {
        _outputContext == .developer
    }

    public nonisolated var isTestMode: Bool {
        _outputContext == .developer
    }

    public nonisolated var isCompiled: Bool {
        _isCompiled
    }

    // MARK: - Template Buffer (ARO-0050)

    public nonisolated func appendToTemplateBuffer(_ value: String) {
        _templateBuffer.append(value)
    }

    public nonisolated func flushTemplateBuffer() -> String {
        let result = _templateBuffer
        _templateBuffer = ""
        return result
    }

    public nonisolated var isTemplateContext: Bool {
        _isTemplateContext
    }

    // MARK: - Schema Registry (ARO-0046)

    /// Get the schema registry for typed event extraction
    /// Falls back to parent context if not set locally
    public nonisolated var schemaRegistry: SchemaRegistry? {
        if let registry = _schemaRegistry {
            return registry
        }
        // Try parent context
        return parent?.schemaRegistry
    }

    /// Set the schema registry (called during application startup)
    /// - Parameter registry: The schema registry to use
    public nonisolated func setSchemaRegistry(_ registry: SchemaRegistry) {
        _schemaRegistry = registry
    }

    // MARK: - Streaming Support (ARO-0051)

    /// Bind a lazy stream without materializing it
    ///
    /// The stream will only be consumed when a drain action (Log, Return, etc.)
    /// is executed on the variable.
    ///
    /// - Parameters:
    ///   - name: Variable name
    ///   - stream: The lazy stream to bind
    public nonisolated func bindLazy<T: Sendable>(_ name: String, stream: AROStream<T>) {
        let value = AROValue<T>.lazy(stream)
        bindStreamingValue(name, value: value)
    }

    /// Bind a streaming value (can be eager or lazy)
    public nonisolated func bindStreamingValue<T: Sendable>(_ name: String, value: AROValue<T>) {
        // Wrap in AnyStreamingValue for type-erased storage
        let anyValue = AnyStreamingValue(value)
        bind(name, value: anyValue)
    }

    /// Resolve a variable as a stream
    ///
    /// This preserves laziness - if the variable is a lazy stream, it returns
    /// the stream without materializing. If it's an eager array, it wraps it.
    ///
    /// - Parameter name: Variable name
    /// - Returns: An AROStream, or nil if variable doesn't exist
    public nonisolated func resolveAsStream<T: Sendable>(_ name: String, as type: T.Type = T.self) -> AROStream<T>? {
        guard let value = resolveAny(name) else {
            return nil
        }

        // If already a streaming value, get stream
        if let anyStreaming = value as? AnyStreamingValue {
            // Try to get typed stream
            if let typedStream = anyStreaming.asStream() as? AROStream<T> {
                return typedStream
            }
            // Fall back to mapping
            return anyStreaming.asStream().compactMap { $0 as? T }
        }

        // If it's an AROValue, unwrap
        if let aroValue = value as? AROValue<T> {
            return aroValue.asStream()
        }

        // If it's an array, wrap as stream
        if let array = value as? [T] {
            return AROStream.from(array)
        }

        // If it's an array of dictionaries (common case)
        if let dictArray = value as? [[String: any Sendable]] {
            if T.self == [String: any Sendable].self {
                return AROStream.from(dictArray as! [T])
            }
        }

        return nil
    }

    /// Resolve a variable as a stream of dictionaries (common case for CSV/JSON)
    public nonisolated func resolveAsRowStream(_ name: String) -> AROStream<[String: any Sendable]>? {
        resolveAsStream(name, as: [String: any Sendable].self)
    }

    /// Check if a variable is a lazy stream (not yet materialized)
    ///
    /// - Parameter name: Variable name
    /// - Returns: true if the variable is a lazy stream
    public nonisolated func isLazy(_ name: String) -> Bool {
        guard let value = resolveAny(name) else {
            return false
        }

        if let anyStreaming = value as? AnyStreamingValue {
            return !anyStreaming.isMaterialized
        }

        return false
    }

    /// Materialize a lazy variable (collect stream into array)
    ///
    /// If the variable is already materialized, this is a no-op.
    /// Otherwise, it consumes the stream and replaces the binding with the array.
    ///
    /// - Parameter name: Variable name
    public nonisolated func materialize(_ name: String) async throws {
        guard let value = resolveAny(name) else {
            return
        }

        if let anyStreaming = value as? AnyStreamingValue, !anyStreaming.isMaterialized {
            let array = try await anyStreaming.materialize()
            // Rebind as eager (using allowRebind since we're replacing the same variable)
            bind(name, value: array, allowRebind: true)
        }
    }

    /// Check if a variable needs to be teed for multiple consumers
    ///
    /// Called by the executor when it detects multiple uses of the same variable.
    /// Returns a teed version of the stream if needed.
    ///
    /// - Parameter name: Variable name
    /// - Parameter consumers: Number of consumers
    public nonisolated func teeIfNeeded(_ name: String, consumers: Int) async {
        guard consumers > 1 else { return }

        guard let value = resolveAny(name) else {
            return
        }

        // Only tee lazy streams
        if let anyStreaming = value as? AnyStreamingValue, !anyStreaming.isMaterialized {
            // The value is already bound - for multi-consumer scenarios,
            // the StreamTee will be created on-demand when consumers are created
            // This is handled by the AROValue.teed() wrapper
        }
    }
}

// MARK: - Convenience Extensions

extension RuntimeContext {
    /// Bind multiple values at once (auto-infers types)
    /// - Parameter bindings: Dictionary of name-value pairs
    public nonisolated func bindAll(_ bindings: [String: any Sendable]) {
        for (name, value) in bindings {
            bind(name, value: value)
        }
    }

    /// Bind multiple typed values at once
    /// - Parameter bindings: Dictionary of name-TypedValue pairs
    public nonisolated func bindAllTyped(_ bindings: [String: TypedValue]) {
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
