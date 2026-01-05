// ============================================================
// ServiceRegistry.swift
// ARO Runtime - External Service Registry
// ============================================================

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Service Protocol

/// Protocol for external service implementations
///
/// Services wrap external libraries (databases, HTTP clients, media processors, etc.)
/// and expose them to ARO via a simple method-call interface.
///
/// ## Example
/// ```swift
/// public struct PostgresService: AROService {
///     public static let name = "postgres"
///
///     public init() {}
///
///     public func call(_ method: String, args: [String: any Sendable]) async throws -> any Sendable {
///         switch method {
///         case "query":
///             let sql = args["sql"] as! String
///             return try await executeQuery(sql)
///         default:
///             throw ServiceError.unknownMethod(method, service: Self.name)
///         }
///     }
/// }
/// ```
public protocol AROService: Sendable {
    /// Service name (e.g., "postgres", "http", "ffmpeg")
    static var name: String { get }

    /// Initialize the service
    init() throws

    /// Call a method on the service
    /// - Parameters:
    ///   - method: Method name (e.g., "query", "get", "transcode")
    ///   - args: Arguments as key-value pairs
    /// - Returns: Result of the method call
    func call(_ method: String, args: [String: any Sendable]) async throws -> any Sendable

    /// Shutdown the service (optional)
    func shutdown() async
}

// MARK: - Default Implementation

public extension AROService {
    /// Default no-op shutdown
    func shutdown() async {}
}

// MARK: - Service Errors

/// Errors that can occur during service operations
public enum ServiceError: Error, CustomStringConvertible, Sendable {
    case serviceNotFound(String)
    case unknownMethod(String, service: String)
    case initializationFailed(String, reason: String)
    case executionFailed(String, method: String, reason: String)
    case invalidArgument(String, expected: String)

    public var description: String {
        switch self {
        case .serviceNotFound(let name):
            return "Service not found: \(name)"
        case .unknownMethod(let method, let service):
            return "Unknown method '\(method)' on service '\(service)'"
        case .initializationFailed(let service, let reason):
            return "Failed to initialize service '\(service)': \(reason)"
        case .executionFailed(let service, let method, let reason):
            return "Service '\(service).\(method)' failed: \(reason)"
        case .invalidArgument(let arg, let expected):
            return "Invalid argument '\(arg)': expected \(expected)"
        }
    }
}

// MARK: - Service Registry

/// Global registry for external services
///
/// Services are registered at application startup and looked up by the `<Call>` action.
///
/// ## Usage
/// ```swift
/// // Register a service
/// ExternalServiceRegistry.shared.register(PostgresService())
///
/// // Call a service method
/// let result = try await ExternalServiceRegistry.shared.call("postgres", method: "query", args: ["sql": "SELECT * FROM users"])
/// ```
public final class ExternalServiceRegistry: @unchecked Sendable {
    /// Shared singleton instance
    public static let shared = ExternalServiceRegistry()

    /// Lock for thread-safe access
    private let lock = NSLock()

    /// Registered services by name
    private var services: [String: any AROService] = [:]

    /// Private initializer - use shared instance
    private init() {
        registerBuiltIns()
    }

    // MARK: - Registration

    /// Register built-in services
    private func registerBuiltIns() {
        // HTTP client is built-in
        do {
            try register(BuiltInHTTPService())
        } catch {
            print("[ExternalServiceRegistry] Warning: Failed to register HTTP service: \(error)")
        }
    }

    /// Register a service
    /// - Parameter service: The service to register
    public func register<S: AROService>(_ service: S) throws {
        lock.lock()
        defer { lock.unlock() }

        let name = S.name.lowercased()
        services[name] = service
    }

    /// Register a service with a custom name
    /// Used by plugin system where the name is determined at runtime
    /// - Parameters:
    ///   - service: The service to register
    ///   - name: Custom name for the service
    public func register(_ service: any AROService, withName name: String) throws {
        lock.lock()
        defer { lock.unlock() }

        services[name.lowercased()] = service
    }

    /// Unregister a service by name
    /// - Parameter name: The service name
    public func unregister(_ name: String) {
        lock.lock()
        defer { lock.unlock() }

        services.removeValue(forKey: name.lowercased())
    }

    /// Check if a service is registered
    /// - Parameter name: The service name
    /// - Returns: true if the service is registered
    public func isRegistered(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return services[name.lowercased()] != nil
    }

    /// Get all registered service names
    public var registeredServices: [String] {
        lock.lock()
        defer { lock.unlock() }

        return Array(services.keys).sorted()
    }

    // MARK: - Service Lookup

    /// Get a service by name
    /// - Parameter name: The service name
    /// - Returns: The service, or nil if not found
    public func service(named name: String) -> (any AROService)? {
        lock.lock()
        defer { lock.unlock() }

        return services[name.lowercased()]
    }

    // MARK: - Service Invocation

    /// Call a method on a service
    /// - Parameters:
    ///   - serviceName: The service name
    ///   - method: The method name
    ///   - args: Arguments as key-value pairs
    /// - Returns: Result of the method call
    public func call(
        _ serviceName: String,
        method: String,
        args: [String: any Sendable]
    ) async throws -> any Sendable {
        guard let service = service(named: serviceName) else {
            throw ServiceError.serviceNotFound(serviceName)
        }

        do {
            return try await service.call(method, args: args)
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.executionFailed(serviceName, method: method, reason: error.localizedDescription)
        }
    }

    // MARK: - Lifecycle

    /// Shutdown all services
    public func shutdownAll() async {
        // Copy services while holding lock (sync), then shutdown (async)
        let servicesToShutdown = getServicesForShutdown()

        for service in servicesToShutdown {
            await service.shutdown()
        }
    }

    /// Get services for shutdown (synchronous helper to avoid async lock issues)
    private func getServicesForShutdown() -> [any AROService] {
        lock.lock()
        defer { lock.unlock() }
        return Array(services.values)
    }
}

// MARK: - Built-in HTTP Client Service

/// Built-in HTTP client service using URLSession
public struct BuiltInHTTPService: AROService {
    public static let name = "http"

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    public func call(_ method: String, args: [String: any Sendable]) async throws -> any Sendable {
        switch method.lowercased() {
        case "get":
            return try await get(args: args)

        case "post":
            return try await post(args: args)

        case "put":
            return try await request(method: "PUT", args: args)

        case "delete":
            return try await request(method: "DELETE", args: args)

        case "patch":
            return try await request(method: "PATCH", args: args)

        default:
            throw ServiceError.unknownMethod(method, service: Self.name)
        }
    }

    private func get(args: [String: any Sendable]) async throws -> any Sendable {
        guard let urlString = args["url"] as? String,
              let url = URL(string: urlString) else {
            throw ServiceError.invalidArgument("url", expected: "valid URL string")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        if let headers = args["headers"] as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        let (data, response) = try await session.data(for: request)
        return formatResponse(data: data, response: response)
    }

    private func post(args: [String: any Sendable]) async throws -> any Sendable {
        return try await request(method: "POST", args: args)
    }

    private func request(method: String, args: [String: any Sendable]) async throws -> any Sendable {
        guard let urlString = args["url"] as? String,
              let url = URL(string: urlString) else {
            throw ServiceError.invalidArgument("url", expected: "valid URL string")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method

        if let headers = args["headers"] as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        if let body = args["body"] {
            if let bodyString = body as? String {
                request.httpBody = bodyString.data(using: .utf8)
            } else if let bodyDict = body as? [String: any Sendable] {
                request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            }
        }

        let (data, response) = try await session.data(for: request)
        return formatResponse(data: data, response: response)
    }

    private func formatResponse(data: Data, response: URLResponse) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]

        if let httpResponse = response as? HTTPURLResponse {
            result["status"] = httpResponse.statusCode
            result["headers"] = Dictionary(uniqueKeysWithValues: httpResponse.allHeaderFields.compactMap { key, value in
                if let keyString = key as? String, let valueString = value as? String {
                    return (keyString, valueString)
                }
                return nil
            })
        }

        // Try to parse as JSON
        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let dict = json as? [String: Any] {
                // Convert to Sendable-safe dictionary
                result["body"] = convertToSendable(dict)
            } else if let array = json as? [Any] {
                result["body"] = convertArrayToSendable(array)
            }
        } else {
            // Return as string
            result["body"] = String(data: data, encoding: .utf8) ?? ""
        }

        return result
    }

    /// Convert a dictionary to Sendable-safe values
    private func convertToSendable(_ dict: [String: Any]) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        for (key, value) in dict {
            result[key] = convertValueToSendable(value)
        }
        return result
    }

    /// Convert an array to Sendable-safe values
    private func convertArrayToSendable(_ array: [Any]) -> [any Sendable] {
        return array.map { convertValueToSendable($0) }
    }

    /// Convert a single value to Sendable
    private func convertValueToSendable(_ value: Any) -> any Sendable {
        switch value {
        case let str as String:
            return str
        case let num as NSNumber:
            // Check if it's a boolean (Apple platforms have CFBoolean APIs)
            #if canImport(Darwin)
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return num.boolValue
            }
            #else
            // On Linux, check type encoding for boolean
            let objCType = String(cString: num.objCType)
            if objCType == "B" || objCType == "c" {
                if num.intValue == 0 || num.intValue == 1 {
                    return num.boolValue
                }
            }
            #endif
            // Check if it's an integer
            if floor(num.doubleValue) == num.doubleValue {
                return num.intValue
            }
            return num.doubleValue
        case let dict as [String: Any]:
            return convertToSendable(dict)
        case let array as [Any]:
            return convertArrayToSendable(array)
        case is NSNull:
            return Optional<String>.none as Any as! (any Sendable)
        default:
            return String(describing: value)
        }
    }

    public func shutdown() async {
        session.invalidateAndCancel()
    }
}
