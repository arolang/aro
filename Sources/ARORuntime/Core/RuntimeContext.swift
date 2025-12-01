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
    private let eventBus: EventBus?

    // MARK: - Metadata

    public let featureSetName: String
    public let executionId: String
    public let parent: ExecutionContext?

    // MARK: - Initialization

    /// Initialize a new runtime context
    /// - Parameters:
    ///   - featureSetName: Name of the feature set being executed
    ///   - eventBus: Optional event bus for event emission
    ///   - parent: Optional parent context for nested execution
    public init(
        featureSetName: String,
        eventBus: EventBus? = nil,
        parent: ExecutionContext? = nil
    ) {
        self.featureSetName = featureSetName
        self.executionId = UUID().uuidString
        self.eventBus = eventBus
        self.parent = parent
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
            eventBus: eventBus,
            parent: self
        )
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
    ///   - eventBus: Optional event bus
    ///   - initialBindings: Initial variable bindings
    /// - Returns: A new context with the bindings
    public static func with(
        featureSetName: String,
        eventBus: EventBus? = nil,
        initialBindings: [String: any Sendable]
    ) -> RuntimeContext {
        let context = RuntimeContext(featureSetName: featureSetName, eventBus: eventBus)
        context.bindAll(initialBindings)
        return context
    }
}
