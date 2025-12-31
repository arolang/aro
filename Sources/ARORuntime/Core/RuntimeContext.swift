// ============================================================
// RuntimeContext.swift
// ARO Runtime - Concrete Execution Context Implementation
// ============================================================

import Foundation

/// Concrete implementation of ExecutionContext
///
/// RuntimeContext provides thread-safe variable storage and service access
/// for executing ARO feature sets.
public final class RuntimeContext: ExecutionContext, @unchecked Sendable {
    // MARK: - Properties

    /// Thread-safe lock for all mutable state
    private let lock = NSLock()

    /// Variable storage
    private var variables: [String: any Sendable] = [:]

    /// Service registry
    private var services: [ObjectIdentifier: any Sendable] = [:]

    /// Repository registry
    private var repositories: [String: Any] = [:]

    /// Current response
    private var _response: Response?

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

        if let value = variables[name] as? T {
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

        if let value = variables[name] {
            return value
        }
        // Try parent context
        return parent?.resolveAny(name)
    }

    public func bind(_ name: String, value: any Sendable) {
        lock.lock()
        defer { lock.unlock() }
        variables[name] = value
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
    /// Bind multiple values at once
    /// - Parameter bindings: Dictionary of name-value pairs
    public func bindAll(_ bindings: [String: any Sendable]) {
        for (name, value) in bindings {
            bind(name, value: value)
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
