// ============================================================
// SystemObjectRegistry.swift
// ARO Runtime - System Object Registry
// ============================================================

import Foundation

// MARK: - System Object Factory

/// Factory for creating system objects with context
public typealias SystemObjectFactory = @Sendable (any ExecutionContext) -> any SystemObject

// MARK: - System Object Registry

/// Registry for system objects
///
/// The registry manages system object factories and provides discovery APIs.
/// System objects can be:
/// - **Static**: Always available (e.g., `console`) - registered with no-context factory
/// - **Context-dependent**: Need execution context (e.g., `request`) - registered with context factory
/// - **Dynamic**: Created with parameters (e.g., `file` with path) - handled specially
///
/// ## Thread Safety
/// The registry is thread-safe and can be accessed concurrently.
///
/// ## Example
/// ```swift
/// // Register static object
/// SystemObjectRegistry.shared.register(ConsoleObject.self)
///
/// // Register context-dependent object
/// SystemObjectRegistry.shared.register("request") { context in
///     RequestObject(from: context)
/// }
///
/// // Get object
/// if let console = SystemObjectRegistry.shared.get("console", context: context) {
///     try await console.write("Hello!")
/// }
/// ```
public final class SystemObjectRegistry: @unchecked Sendable {
    /// Shared singleton instance
    public static let shared = SystemObjectRegistry()

    /// Registered factories keyed by identifier
    private var factories: [String: SystemObjectFactory] = [:]

    /// Metadata about registered objects
    private var metadata: [String: SystemObjectMetadata] = [:]

    /// Lock for thread-safe access
    private let lock = NSLock()

    // MARK: - Initialization

    private init() {
        // Register built-in objects on initialization
        registerBuiltIns()
    }

    // MARK: - Registration

    /// Register a static system object type
    ///
    /// Use this for objects that don't need execution context and can be
    /// instantiated without parameters (e.g., `console`, `env`).
    ///
    /// - Parameter type: The system object type to register
    public func register<T: SystemObject & Instantiable>(_ type: T.Type) {
        lock.lock()
        defer { lock.unlock() }

        factories[T.identifier] = { _ in T() }
        metadata[T.identifier] = SystemObjectMetadata(
            identifier: T.identifier,
            description: T.description,
            capabilities: T().capabilities,
            isStatic: true
        )
    }

    /// Register a context-dependent system object factory
    ///
    /// Use this for objects that need execution context to be created
    /// (e.g., `request` which needs HTTP request from context).
    ///
    /// - Parameters:
    ///   - identifier: The object identifier (e.g., "request")
    ///   - description: Human-readable description
    ///   - capabilities: What operations the object supports
    ///   - factory: Factory closure that creates the object
    public func register(
        _ identifier: String,
        description: String = "",
        capabilities: SystemObjectCapabilities = .bidirectional,
        factory: @escaping SystemObjectFactory
    ) {
        lock.lock()
        defer { lock.unlock() }

        factories[identifier] = factory
        metadata[identifier] = SystemObjectMetadata(
            identifier: identifier,
            description: description,
            capabilities: capabilities,
            isStatic: false
        )
    }

    /// Unregister a system object
    ///
    /// - Parameter identifier: The object identifier to remove
    public func unregister(_ identifier: String) {
        lock.lock()
        defer { lock.unlock() }

        factories.removeValue(forKey: identifier)
        metadata.removeValue(forKey: identifier)
    }

    // MARK: - Retrieval

    /// Get a system object by identifier
    ///
    /// - Parameters:
    ///   - identifier: The object identifier (e.g., "console", "request")
    ///   - context: The execution context for context-dependent objects
    /// - Returns: The system object if registered, nil otherwise
    public func get(_ identifier: String, context: any ExecutionContext) -> (any SystemObject)? {
        lock.lock()
        let factory = factories[identifier]
        lock.unlock()

        return factory?(context)
    }

    /// Check if a system object is registered
    ///
    /// - Parameter identifier: The object identifier to check
    /// - Returns: true if registered
    public func isRegistered(_ identifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return factories[identifier] != nil
    }

    /// Get metadata for a system object
    ///
    /// - Parameter identifier: The object identifier
    /// - Returns: Metadata if registered, nil otherwise
    public func getMetadata(_ identifier: String) -> SystemObjectMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return metadata[identifier]
    }

    // MARK: - Discovery

    /// All registered object identifiers (sorted)
    public var identifiers: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(factories.keys).sorted()
    }

    /// All registered metadata
    public var allMetadata: [SystemObjectMetadata] {
        lock.lock()
        defer { lock.unlock() }
        return Array(metadata.values).sorted { $0.identifier < $1.identifier }
    }

    /// Get identifiers filtered by capabilities
    ///
    /// - Parameter capabilities: Required capabilities
    /// - Returns: Identifiers of objects with those capabilities
    public func identifiers(with capabilities: SystemObjectCapabilities) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        return metadata
            .filter { $0.value.capabilities.contains(capabilities) }
            .map { $0.key }
            .sorted()
    }

    /// Get all source objects (readable)
    public var sourceIdentifiers: [String] {
        identifiers(with: .readable)
    }

    /// Get all sink objects (writable)
    public var sinkIdentifiers: [String] {
        identifiers(with: .writable)
    }

    // MARK: - Built-in Registration

    private func registerBuiltIns() {
        // Register all built-in system objects
        registerBuiltInObjects()
    }
}

// MARK: - System Object Metadata

/// Metadata about a registered system object
public struct SystemObjectMetadata: Sendable {
    /// The object identifier
    public let identifier: String

    /// Human-readable description
    public let description: String

    /// What operations the object supports
    public let capabilities: SystemObjectCapabilities

    /// Whether this is a static object (no context needed)
    public let isStatic: Bool

    public init(
        identifier: String,
        description: String,
        capabilities: SystemObjectCapabilities,
        isStatic: Bool
    ) {
        self.identifier = identifier
        self.description = description
        self.capabilities = capabilities
        self.isStatic = isStatic
    }
}

// MARK: - Convenience Extensions

public extension SystemObjectRegistry {
    /// Read from a system object
    ///
    /// Convenience method that gets the object and reads from it.
    ///
    /// - Parameters:
    ///   - identifier: The object identifier
    ///   - property: Optional property path
    ///   - context: The execution context
    /// - Returns: The read value
    /// - Throws: SystemObjectError if object not found or not readable
    func read(
        from identifier: String,
        property: String? = nil,
        context: any ExecutionContext
    ) async throws -> any Sendable {
        guard let object = get(identifier, context: context) else {
            throw SystemObjectError.notFound(identifier)
        }
        guard object.capabilities.isReadable else {
            throw SystemObjectError.notReadable(identifier)
        }
        return try await object.read(property: property)
    }

    /// Write to a system object
    ///
    /// Convenience method that gets the object and writes to it.
    ///
    /// - Parameters:
    ///   - value: The value to write
    ///   - identifier: The object identifier
    ///   - context: The execution context
    /// - Throws: SystemObjectError if object not found or not writable
    func write(
        _ value: any Sendable,
        to identifier: String,
        context: any ExecutionContext
    ) async throws {
        guard let object = get(identifier, context: context) else {
            throw SystemObjectError.notFound(identifier)
        }
        guard object.capabilities.isWritable else {
            throw SystemObjectError.notWritable(identifier)
        }
        try await object.write(value)
    }
}
