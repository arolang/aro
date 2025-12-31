// ============================================================
// SystemObject.swift
// ARO Runtime - System Object Protocol
// ============================================================

import Foundation

// MARK: - System Object Capabilities

/// Defines what operations a system object supports
public struct SystemObjectCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Object can be read from (source)
    public static let readable = SystemObjectCapabilities(rawValue: 1 << 0)

    /// Object can be written to (sink)
    public static let writable = SystemObjectCapabilities(rawValue: 1 << 1)

    // MARK: - Convenience Aliases

    /// Source object - can only be read from
    public static let source: SystemObjectCapabilities = [.readable]

    /// Sink object - can only be written to
    public static let sink: SystemObjectCapabilities = [.writable]

    /// Bidirectional object - can be read from and written to
    public static let bidirectional: SystemObjectCapabilities = [.readable, .writable]

    // MARK: - Helpers

    /// Whether this object supports reading
    public var isReadable: Bool { contains(.readable) }

    /// Whether this object supports writing
    public var isWritable: Bool { contains(.writable) }
}

// MARK: - System Object Protocol

/// Protocol for system objects - sources (read from) and sinks (write to)
///
/// System objects are ARO's "magic" built-in objects like `console`, `request`, `file`, etc.
/// They provide a unified interface for reading from and writing to various I/O targets.
///
/// ## Categories
///
/// 1. **Static objects**: Always available (e.g., `console`, `env`)
/// 2. **Context objects**: Available based on execution context (e.g., `request` in HTTP handlers)
/// 3. **Dynamic objects**: Created with parameters (e.g., `file` with path qualifier)
///
/// ## Example Implementation
///
/// ```swift
/// public struct ConsoleObject: SystemObject {
///     public static let identifier = "console"
///     public static let description = "Standard output stream"
///     public var capabilities: SystemObjectCapabilities { .sink }
///
///     public func write(_ value: any Sendable) async throws {
///         print(value)
///     }
///
///     public func read(property: String?) async throws -> any Sendable {
///         throw SystemObjectError.notReadable(Self.identifier)
///     }
/// }
/// ```
public protocol SystemObject: Sendable {
    /// Unique identifier used in ARO code (e.g., "console", "request", "file")
    static var identifier: String { get }

    /// Human-readable description of this system object
    static var description: String { get }

    /// What operations this object supports (source, sink, or bidirectional)
    var capabilities: SystemObjectCapabilities { get }

    /// Read from this object (for sources)
    ///
    /// - Parameter property: Optional property path to read (e.g., "body", "headers.authorization")
    /// - Returns: The read value
    /// - Throws: `SystemObjectError.notReadable` if this is a sink-only object
    func read(property: String?) async throws -> any Sendable

    /// Write to this object (for sinks)
    ///
    /// - Parameter value: The value to write
    /// - Throws: `SystemObjectError.notWritable` if this is a source-only object
    func write(_ value: any Sendable) async throws
}

// MARK: - Default Implementations

public extension SystemObject {
    /// Default read implementation that throws notReadable error
    func read(property: String?) async throws -> any Sendable {
        throw SystemObjectError.notReadable(Self.identifier)
    }

    /// Default write implementation that throws notWritable error
    func write(_ value: any Sendable) async throws {
        throw SystemObjectError.notWritable(Self.identifier)
    }
}

// MARK: - System Object Error

/// Errors that can occur when interacting with system objects
public enum SystemObjectError: Error, CustomStringConvertible, Sendable {
    /// The system object does not support reading
    case notReadable(String)

    /// The system object does not support writing
    case notWritable(String)

    /// The system object was not found in the registry
    case notFound(String)

    /// A requested property was not found on the system object
    case propertyNotFound(String, in: String)

    /// The system object is not available in the current context
    case notAvailableInContext(String, context: String)

    /// Type mismatch when writing to the system object
    case typeMismatch(expected: String, actual: String, object: String)

    /// Read operation failed (e.g., plugin error)
    case readFailed(String, message: String)

    /// Write operation failed (e.g., plugin error)
    case writeFailed(String, message: String)

    /// Invalid path provided (e.g., directory traversal attempt)
    case invalidPath(String, reason: String)

    public var description: String {
        switch self {
        case .notReadable(let id):
            return "System object '\(id)' is not readable (sink only)"
        case .notWritable(let id):
            return "System object '\(id)' is not writable (source only)"
        case .notFound(let id):
            return "System object '\(id)' not found"
        case .propertyNotFound(let prop, let id):
            return "Property '\(prop)' not found in system object '\(id)'"
        case .notAvailableInContext(let id, let context):
            return "System object '\(id)' is not available in \(context) context"
        case .typeMismatch(let expected, let actual, let object):
            return "Type mismatch for system object '\(object)': expected \(expected), got \(actual)"
        case .readFailed(let id, let message):
            return "Failed to read from system object '\(id)': \(message)"
        case .writeFailed(let id, let message):
            return "Failed to write to system object '\(id)': \(message)"
        case .invalidPath(let path, let reason):
            return "Invalid file path '\(path)': \(reason)"
        }
    }
}

// MARK: - Instantiable Protocol

/// Marker protocol for system objects that can be instantiated without parameters
public protocol Instantiable {
    init()
}
