// ============================================================
// ResponseActions.swift
// ARO Runtime - Response Action Implementations
// ============================================================

import Foundation
import AROParser

/// Returns a response from a feature set
///
/// The Return action is a RESPONSE action that sets the output of the
/// current feature set execution. It terminates the execution flow.
///
/// ## Example
/// ```
/// <Return> an <OK: status> for a <valid: authentication>.
/// ```
public struct ReturnAction: ActionImplementation {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["return", "respond"]
    public static let validPrepositions: Set<Preposition> = [.for, .to, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        let statusName = result.base
        let reason = object.base

        // Gather any data to include in response
        var data: [String: AnySendable] = [:]

        // Include object specifiers as data references
        for specifier in object.specifiers {
            if let value: String = context.resolve(specifier) {
                data[specifier] = AnySendable(value)
            } else if let value: Int = context.resolve(specifier) {
                data[specifier] = AnySendable(value)
            } else if let value: Bool = context.resolve(specifier) {
                data[specifier] = AnySendable(value)
            } else if let value: Double = context.resolve(specifier) {
                data[specifier] = AnySendable(value)
            }
        }

        let response = Response(
            status: statusName,
            reason: reason,
            data: data
        )

        context.setResponse(response)
        return response
    }
}

/// Throws an error
public struct ThrowAction: ActionImplementation {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["throw", "raise", "fail"]
    public static let validPrepositions: Set<Preposition> = [.for]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        let errorType = result.base
        let reason = object.fullName

        throw ActionError.thrown(
            type: errorType,
            reason: reason,
            context: context.featureSetName
        )
    }
}

/// Sends data to an external destination
public struct SendAction: ActionImplementation {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["send", "emit", "dispatch"]
    public static let validPrepositions: Set<Preposition> = [.to, .via]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get data to send
        guard let data = context.resolveAny(result.base) else {
            print("[SendAction] ERROR: Could not resolve data variable '\(result.base)'")
            throw ActionError.undefinedVariable(result.base)
        }
        print("[SendAction] Data to send: \(type(of: data)) = \(data)")

        // Get destination - could be a connection ID variable or literal
        let destination: String
        if let resolvedDest: String = context.resolve(object.base) {
            destination = resolvedDest
        } else {
            destination = object.base
        }
        print("[SendAction] Destination: \(destination)")

        // Try socket server service first (for socket connections)
        #if !os(Windows)
        if let socketServer = context.service(SocketServerService.self) {
            print("[SendAction] Found SocketServerService, attempting to send...")
            // Try to send to socket connection
            do {
                if let dataValue = data as? Data {
                    print("[SendAction] Sending as Data (\(dataValue.count) bytes)")
                    try await socketServer.send(data: dataValue, to: destination)
                } else if let stringValue = data as? String {
                    print("[SendAction] Sending as String")
                    try await socketServer.send(string: stringValue, to: destination)
                } else {
                    // Convert to string
                    print("[SendAction] Sending as converted String")
                    try await socketServer.send(string: String(describing: data), to: destination)
                }
                print("[SendAction] Send succeeded!")
                return SendResult(destination: destination, success: true)
            } catch {
                // Connection not found - fall through to other services
                print("[SendAction] Socket send failed: \(error)")
            }
        } else {
            print("[SendAction] SocketServerService NOT FOUND in context")
        }
        #endif

        // Try messaging service
        if let messagingService = context.service(MessagingService.self) {
            try await messagingService.send(data: data, to: destination)
            return SendResult(destination: destination, success: true)
        }

        // Emit as event
        context.emit(MessageSentEvent(destination: destination, data: String(describing: data)))

        return SendResult(destination: destination, success: true)
    }
}

/// Logs a message
public struct LogAction: ActionImplementation {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["log", "print", "output", "debug"]
    public static let validPrepositions: Set<Preposition> = [.for, .to, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get message to log
        let message: String
        if let value: String = context.resolve(result.base) {
            message = value
        } else if let value = context.resolveAny(result.base) {
            message = String(describing: value)
        } else {
            message = result.fullName
        }

        // Get log target (e.g., console, file)
        let target = object.base

        // Try logging service
        if let loggingService = context.service(LoggingService.self) {
            await loggingService.log(message: message, target: target, level: .info)
            return LogResult(message: message, target: target)
        }

        // Fallback to print
        print("[\(context.featureSetName)] \(message)")

        return LogResult(message: message, target: target)
    }
}

/// Stores data to a repository
public struct StoreAction: ActionImplementation {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["store", "save", "persist"]
    public static let validPrepositions: Set<Preposition> = [.into, .to, .in]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get data to store
        guard let data = context.resolveAny(result.base) else {
            throw ActionError.undefinedVariable(result.base)
        }

        // Get repository name
        let repoName = object.base

        // Emit store event
        context.emit(DataStoredEvent(repository: repoName, dataType: String(describing: type(of: data))))

        return StoreResult(repository: repoName, success: true)
    }
}

/// Writes data to a file
public struct WriteAction: ActionImplementation {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["write"]
    public static let validPrepositions: Set<Preposition> = [.to, .into]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get data to write
        let content: String
        if let value: String = context.resolve(result.base) {
            content = value
        } else if let value = context.resolveAny(result.base) {
            content = String(describing: value)
        } else {
            content = ""
        }

        // Get file path
        let path: String
        if let resolvedPath: String = context.resolve(object.base) {
            path = resolvedPath
        } else {
            path = object.base
        }

        // Try file service
        if let fileService = context.service(FileSystemService.self) {
            try await fileService.write(path: path, content: content)
            return WriteResult(path: path, success: true)
        }

        throw ActionError.missingService("FileSystemService")
    }
}

/// Publishes a variable for cross-feature-set access
public struct PublishAction: ActionImplementation {
    public static let role: ActionRole = .export
    public static let verbs: Set<String> = ["publish", "export", "expose", "share"]
    public static let validPrepositions: Set<Preposition> = [.with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Publish is handled specially - the external name is in result, internal in object
        guard let value = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // The result.base is the external name to publish as
        // This is typically handled by the execution engine's global registry
        context.emit(VariablePublishedEvent(
            externalName: result.base,
            internalName: object.base,
            featureSet: context.featureSetName
        ))

        // value is already `any Sendable` from resolveAny
        return value
    }
}

// MARK: - Supporting Types

/// Messaging service protocol
public protocol MessagingService: Sendable {
    func send(data: Any, to destination: String) async throws
}

/// Logging service protocol
public protocol LoggingService: Sendable {
    func log(message: String, target: String, level: LogLevel) async
}

/// Log levels
public enum LogLevel: String, Sendable {
    case debug, info, warning, error
}

/// Result of a send operation
public struct SendResult: Sendable, Equatable {
    public let destination: String
    public let success: Bool
}

/// Result of a log operation
public struct LogResult: Sendable, Equatable {
    public let message: String
    public let target: String
}

/// Result of a store operation
public struct StoreResult: Sendable, Equatable {
    public let repository: String
    public let success: Bool
}

/// Result of a write operation
public struct WriteResult: Sendable, Equatable {
    public let path: String
    public let success: Bool
}

// MARK: - Supporting Events

/// Event emitted when a message is sent
public struct MessageSentEvent: RuntimeEvent {
    public static var eventType: String { "message.sent" }
    public let timestamp: Date
    public let destination: String
    public let data: String

    public init(destination: String, data: String) {
        self.timestamp = Date()
        self.destination = destination
        self.data = data
    }
}

/// Event emitted when data is stored
public struct DataStoredEvent: RuntimeEvent {
    public static var eventType: String { "data.stored" }
    public let timestamp: Date
    public let repository: String
    public let dataType: String

    public init(repository: String, dataType: String) {
        self.timestamp = Date()
        self.repository = repository
        self.dataType = dataType
    }
}

/// Event emitted when a variable is published
public struct VariablePublishedEvent: RuntimeEvent {
    public static var eventType: String { "variable.published" }
    public let timestamp: Date
    public let externalName: String
    public let internalName: String
    public let featureSet: String

    public init(externalName: String, internalName: String, featureSet: String) {
        self.timestamp = Date()
        self.externalName = externalName
        self.internalName = internalName
        self.featureSet = featureSet
    }
}
