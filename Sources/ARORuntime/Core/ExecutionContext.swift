// ============================================================
// ExecutionContext.swift
// ARO Runtime - Execution Context
// ============================================================

import Foundation

// MARK: - Response

/// Response from feature set execution
public struct Response: Sendable, Equatable {
    /// Status name (e.g., "OK", "Forbidden", "NotFound")
    public let status: String

    /// Reason or description
    public let reason: String

    /// Response data
    public let data: [String: AnySendable]

    public init(status: String, reason: String = "", data: [String: AnySendable] = [:]) {
        self.status = status
        self.reason = reason
        self.data = data
    }

    /// Common responses
    public static func ok(_ data: [String: AnySendable] = [:]) -> Response {
        Response(status: "OK", reason: "success", data: data)
    }

    public static func error(_ reason: String, data: [String: AnySendable] = [:]) -> Response {
        Response(status: "Error", reason: reason, data: data)
    }
}

// MARK: - AnySendable Wrapper

/// Type-erased Sendable wrapper for storing heterogeneous values
public struct AnySendable: Sendable, Equatable {
    private let value: any Sendable
    private let equals: @Sendable (any Sendable) -> Bool

    public init<T: Sendable & Equatable>(_ value: T) {
        self.value = value
        self.equals = { other in
            guard let otherValue = other as? T else { return false }
            return value == otherValue
        }
    }

    /// Get the underlying value
    public func get<T>() -> T? {
        value as? T
    }

    public static func == (lhs: AnySendable, rhs: AnySendable) -> Bool {
        lhs.equals(rhs.value)
    }
}

// MARK: - Runtime Event

/// Protocol for runtime events
public protocol RuntimeEvent: Sendable {
    /// Event type identifier
    static var eventType: String { get }

    /// Timestamp when the event occurred
    var timestamp: Date { get }
}

// MARK: - Repository Protocol

/// Protocol for data repositories
public protocol Repository<Entity>: Sendable {
    associatedtype Entity: Sendable

    /// Find an entity by query
    func find(_ query: Query) async throws -> Entity?

    /// Find all entities matching query
    func findAll(_ query: Query) async throws -> [Entity]

    /// Save an entity
    func save(_ entity: Entity) async throws

    /// Delete an entity
    func delete(_ entity: Entity) async throws
}

/// Query for repository operations
public struct Query: Sendable {
    public let type: String
    public let fields: [String]
    public let predicate: String?

    public init(type: String, fields: [String] = [], predicate: String? = nil) {
        self.type = type
        self.fields = fields
        self.predicate = predicate
    }
}

// MARK: - Execution Context Protocol

/// Protocol for runtime execution context
///
/// The execution context provides:
/// - Variable binding and resolution
/// - Service access (dependency injection)
/// - Repository access for data operations
/// - Response management
/// - Event emission
public protocol ExecutionContext: AnyObject, Sendable {
    // MARK: - Variable Management

    /// Resolve a variable by name
    /// - Parameter name: The variable name to look up
    /// - Returns: The value if found and of correct type, nil otherwise
    func resolve<T: Sendable>(_ name: String) -> T?

    /// Resolve a variable by name as any Sendable
    /// - Parameter name: The variable name to look up
    /// - Returns: The value if found, nil otherwise
    func resolveAny(_ name: String) -> (any Sendable)?

    /// Resolve a variable, throwing if not found
    /// - Parameter name: The variable name to look up
    /// - Returns: The value
    /// - Throws: ActionError.undefinedVariable if not found
    func require<T: Sendable>(_ name: String) throws -> T

    /// Bind a value to a variable name
    /// - Parameters:
    ///   - name: The variable name
    ///   - value: The value to bind
    func bind(_ name: String, value: any Sendable)

    /// Check if a variable exists
    /// - Parameter name: The variable name to check
    /// - Returns: true if the variable is defined
    func exists(_ name: String) -> Bool

    /// Get all variable names in scope
    var variableNames: Set<String> { get }

    // MARK: - Service Access

    /// Get a registered service by type
    /// - Parameter type: The service type to look up
    /// - Returns: The service instance if registered, nil otherwise
    func service<S>(_ type: S.Type) -> S?

    /// Register a service
    /// - Parameter service: The service instance to register
    func register<S: Sendable>(_ service: S)

    /// Register a service with an explicit type ID (for preserving type info across type-erased collections)
    /// - Parameters:
    ///   - typeId: The ObjectIdentifier for the service type
    ///   - service: The service instance to register
    func registerWithTypeId(_ typeId: ObjectIdentifier, service: any Sendable)

    // MARK: - Repository Access

    /// Get a repository by name
    /// - Parameter named: The repository name
    /// - Returns: The repository if registered, nil otherwise
    func repository<T: Sendable>(named: String) -> (any Repository<T>)?

    /// Register a repository
    /// - Parameters:
    ///   - name: The repository name
    ///   - repository: The repository instance
    func registerRepository<T: Sendable>(name: String, repository: any Repository<T>)

    // MARK: - Response Management

    /// Set the response for this execution
    /// - Parameter response: The response to set
    func setResponse(_ response: Response)

    /// Get the current response
    /// - Returns: The response if set, nil otherwise
    func getResponse() -> Response?

    // MARK: - Event Emission

    /// Emit an event to the event bus
    /// - Parameter event: The event to emit
    func emit(_ event: any RuntimeEvent)

    // MARK: - Metadata

    /// The feature set being executed
    var featureSetName: String { get }

    /// Unique identifier for this execution
    var executionId: String { get }

    /// Parent context (for nested scopes)
    var parent: ExecutionContext? { get }

    /// Create a child context for nested execution
    /// - Parameter featureSetName: Name of the child feature set
    /// - Returns: A new child context
    func createChild(featureSetName: String) -> ExecutionContext

    // MARK: - Wait State Management

    /// Enter wait state - signals the application should stay alive for events
    func enterWaitState()

    /// Wait for shutdown signal (blocks until application should terminate)
    func waitForShutdown() async throws

    /// Check if the context is in wait state
    var isWaiting: Bool { get }

    /// Signal that the wait should end
    func signalShutdown()
}

// MARK: - Default Implementations

public extension ExecutionContext {
    func require<T: Sendable>(_ name: String) throws -> T {
        guard let value: T = resolve(name) else {
            throw ActionError.undefinedVariable(name)
        }
        return value
    }
}
