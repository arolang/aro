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

        // Check for expression from "with" clause (e.g., with { user: <user>, ... } or with <variable>)
        // Note: When with clause contains variable references, it's parsed as expression
        if let expr = context.resolveAny("_expression_") {
            if let dict = expr as? [String: any Sendable] {
                // Map literal: { key: value, ... } - preserve nested structure
                for (key, value) in dict {
                    flattenValue(value, into: &data, prefix: key, context: context)
                }
            } else if let array = expr as? [any Sendable] {
                // Array value - serialize to JSON
                let jsonArray = array.map { convertSendableToJSON($0) }
                if let jsonData = try? JSONSerialization.data(withJSONObject: jsonArray),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    data["data"] = AnySendable(jsonString)
                } else {
                    data["data"] = AnySendable("[]")
                }
            } else if let str = expr as? String {
                // Simple variable that contains a JSON string - try to parse it
                if let jsonData = str.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: jsonData),
                   let dict = parsed as? [String: Any] {
                    // Variable contains JSON object - use it directly as response data
                    for (key, value) in dict {
                        addAnyValue(value, into: &data, key: key)
                    }
                } else {
                    // Plain string value
                    data["value"] = AnySendable(str)
                }
            } else if let int = expr as? Int {
                data["value"] = AnySendable(int)
            } else if let double = expr as? Double {
                data["value"] = AnySendable(double)
            } else if let bool = expr as? Bool {
                data["value"] = AnySendable(bool)
            }
        }

        // Check for object literal from "with" clause (for simple literals without var refs)
        if let literal = context.resolveAny("_literal_") {
            if let dict = literal as? [String: any Sendable] {
                for (key, value) in dict {
                    flattenValue(value, into: &data, prefix: key, context: context)
                }
            }
        }

        // Include object.base value if resolvable (skip internal names already handled above)
        let internalNames: Set<String> = ["_expression_", "_literal_", "status", "response"]
        if !internalNames.contains(object.base), let value = context.resolveAny(object.base) {
            flattenValue(value, into: &data, prefix: object.base, context: context)
        }

        // Include object specifiers as data references (skip internal names)
        for specifier in object.specifiers where !internalNames.contains(specifier) {
            if let value = context.resolveAny(specifier) {
                flattenValue(value, into: &data, prefix: specifier, context: context)
            }
        }

        // If data is empty, try to add a reasonable default value from context
        // This matches compiled binary behavior which includes return values
        if data.isEmpty {
            // Try to find any non-internal variable that might be a return value
            // Common patterns: last created/modified value, greeting, message, result, etc.
            let candidateKeys = ["greeting", "message", "result", "data", "output", "value"]
            for key in candidateKeys {
                if let value = context.resolveAny(key) {
                    // Convert to string since AnySendable requires Equatable
                    if let str = value as? String {
                        data["value"] = AnySendable(str)
                    } else {
                        data["value"] = AnySendable(String(describing: value))
                    }
                    break
                }
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

    /// Flatten a value into the data dictionary using dot notation for nested objects
    private func flattenValue(
        _ value: any Sendable,
        into data: inout [String: AnySendable],
        prefix: String,
        context: ExecutionContext
    ) {
        switch value {
        case let str as String:
            // Check if it's a variable reference
            if let resolved = context.resolveAny(str) {
                flattenValue(resolved, into: &data, prefix: prefix, context: context)
            } else {
                data[prefix] = AnySendable(str)
            }
        case let int as Int:
            data[prefix] = AnySendable(int)
        case let double as Double:
            data[prefix] = AnySendable(double)
        case let bool as Bool:
            data[prefix] = AnySendable(bool)
        case let dict as [String: any Sendable]:
            // Recursively flatten nested dictionaries with dot notation
            for (key, nestedValue) in dict {
                let nestedPrefix = "\(prefix).\(key)"
                flattenValue(nestedValue, into: &data, prefix: nestedPrefix, context: context)
            }
        case let array as [any Sendable]:
            // Arrays are serialized as JSON strings
            let jsonArray = array.map { convertSendableToJSON($0) }
            if let jsonData = try? JSONSerialization.data(withJSONObject: jsonArray),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                data[prefix] = AnySendable(jsonString)
            } else {
                data[prefix] = AnySendable("[]")
            }
        default:
            data[prefix] = AnySendable(String(describing: value))
        }
    }

    /// Format an array item as a string
    private func formatArrayItem(_ value: any Sendable, context: ExecutionContext) -> String {
        switch value {
        case let str as String:
            if let resolved = context.resolveAny(str) {
                return formatArrayItem(resolved, context: context)
            }
            return str
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(double)
        case let bool as Bool:
            return bool ? "true" : "false"
        default:
            return String(describing: value)
        }
    }

    /// Convert a Sendable value to a JSON-compatible type
    private func convertSendableToJSON(_ value: any Sendable) -> Any {
        switch value {
        case let str as String:
            return str
        case let int as Int:
            return int
        case let double as Double:
            return double
        case let bool as Bool:
            return bool
        case let dict as [String: any Sendable]:
            var result: [String: Any] = [:]
            for (k, v) in dict {
                result[k] = convertSendableToJSON(v)
            }
            return result
        case let array as [any Sendable]:
            return array.map { convertSendableToJSON($0) }
        default:
            return String(describing: value)
        }
    }

    /// Add a value from JSON parsing (Any type) into the data dictionary
    /// Nested structures are serialized as JSON strings since AnySendable requires Equatable
    private func addAnyValue(_ value: Any, into data: inout [String: AnySendable], key: String) {
        switch value {
        case let str as String:
            data[key] = AnySendable(str)
        case let int as Int:
            data[key] = AnySendable(int)
        case let double as Double:
            data[key] = AnySendable(double)
        case let bool as Bool:
            data[key] = AnySendable(bool)
        case let dict as [String: Any]:
            // Nested dict - serialize as JSON string (will be parsed back for HTTP response)
            if let jsonData = try? JSONSerialization.data(withJSONObject: dict),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                data[key] = AnySendable(jsonString)
            } else {
                data[key] = AnySendable(String(describing: dict))
            }
        case let array as [Any]:
            // Array - serialize as JSON string
            if let jsonData = try? JSONSerialization.data(withJSONObject: array),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                data[key] = AnySendable(jsonString)
            } else {
                data[key] = AnySendable(String(describing: array))
            }
        default:
            data[key] = AnySendable(String(describing: value))
        }
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
    public static let verbs: Set<String> = ["send", "dispatch"]
    public static let validPrepositions: Set<Preposition> = [.to, .via, .with]

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
        // Priority:
        //   1. Metrics with format qualifier (ARO-0044)
        //   2. Result expression (ARO-0043 sink syntax: <Log> "message" to the <console>)
        //   3. With clause literal
        //   4. With clause expression
        //   5. Result variable
        //   6. Fallback to result fullName
        let message: String

        // ARO-0044: Check for metrics magic variable with format qualifier
        // <Log> the <metrics: plain/short/table/prometheus> to the <console>
        if result.base == "metrics" {
            if let metricsSnapshot = context.resolveAny("metrics") as? MetricsSnapshot {
                let format = result.specifiers.first ?? "plain"
                message = MetricsFormatter.format(metricsSnapshot, as: format, context: context.outputContext)
            } else {
                message = "No metrics available"
            }
        } else if let resultExpr = context.resolveAny("_result_expression_") {
            // ARO-0043: Message from sink syntax result expression
            message = ResponseFormatter.formatValue(resultExpr, for: context.outputContext)
        } else if let literal = context.resolveAny("_literal_") {
            // Message from "with" clause (string literal)
            message = ResponseFormatter.formatValue(literal, for: context.outputContext)
        } else if let expr = context.resolveAny("_expression_") {
            // Message from "with" clause (expression)
            message = ResponseFormatter.formatValue(expr, for: context.outputContext)
        } else if let value: String = context.resolve(result.base) {
            // Message from variable
            message = value
        } else if let value = context.resolveAny(result.base) {
            // Message from any variable type
            message = ResponseFormatter.formatValue(value, for: context.outputContext)
        } else {
            // Fallback to result name
            message = result.fullName
        }

        // Get log target (e.g., console, file)
        let target = object.base

        // Extract output stream qualifier (for console: stdout vs stderr)
        // Default to "output" (stdout) if no qualifier specified
        let outputStream: String
        if let qualifier = object.specifiers.first {
            outputStream = qualifier.lowercased()
        } else {
            outputStream = "output"  // default to stdout
        }

        // Try logging service
        if let loggingService = context.service(LoggingService.self) {
            await loggingService.log(message: message, target: target, level: .info)
            return LogResult(message: message, target: target)
        }

        // Fallback to print with context-aware formatting
        let formattedMessage: String
        switch context.outputContext {
        case .machine:
            // JSON format for machine consumption
            formattedMessage = "{\"level\":\"info\",\"source\":\"\(context.featureSetName)\",\"message\":\"\(message.replacingOccurrences(of: "\"", with: "\\\""))\"}"
        case .human:
            // Readable format for CLI/console
            // Compiled binaries get clean output without feature set prefix
            if context.isCompiled {
                formattedMessage = message
            } else {
                formattedMessage = "[\(context.featureSetName)] \(message)"
            }
        case .developer:
            // Diagnostic format for testing/debugging
            formattedMessage = "LOG[\(target)] \(context.featureSetName): \(message)"
        }

        // Route output to appropriate stream based on target and qualifier
        // Check if target is "stderr" (backward compatibility) OR qualifier is "error"
        if target.lowercased() == "stderr" || outputStream == "error" {
            // Write to stderr using FileHandle for concurrency safety
            if let data = (formattedMessage + "\n").data(using: .utf8) {
                try FileHandle.standardError.write(contentsOf: data)
            }
        } else {
            // Write to stdout (default behavior)
            print(formattedMessage)
        }

        return LogResult(message: message, target: target)
    }
}

/// Stores data to a repository
///
/// When the target name ends with `-repository`, the data is stored in
/// the RepositoryStorage service, which persists across HTTP requests
/// within the same business activity.
///
/// ## Example
/// ```
/// <Store> the <message> into the <message-repository>.
/// ```
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

        // Check if this is a repository (ends with -repository)
        if InMemoryRepositoryStorage.isRepositoryName(repoName) {
            // Store in repository storage service with change tracking
            let storeResult: RepositoryStoreResult
            if let storage = context.service(RepositoryStorageService.self) {
                storeResult = await storage.storeWithChangeInfo(
                    value: data,
                    in: repoName,
                    businessActivity: context.businessActivity
                )
            } else {
                // Fallback to shared instance if service not registered
                storeResult = await InMemoryRepositoryStorage.shared.storeWithChangeInfo(
                    value: data,
                    in: repoName,
                    businessActivity: context.businessActivity
                )
            }

            // Note: We don't rebind the result variable here to maintain immutability
            // The stored value (with auto-generated ID if applicable) is returned from execute()

            // Emit repository change event(s) for observers
            // If data is an array, emit one event per item
            // Otherwise, emit a single event (backward compatible)
            if let arrayData = storeResult.storedValue as? [any Sendable] {
                // List storage: emit event for EACH item
                for item in arrayData {
                    // Try to extract entityId from item if it's a dictionary
                    var itemId: String? = nil
                    if let dict = item as? [String: Any] {
                        if let id = dict["id"] as? String {
                            itemId = id
                        } else if let id = dict["id"] as? Int {
                            itemId = String(id)
                        }
                    }

                    // Use publishAndTrack to ensure runtime waits for observers to complete
                    if let eventBus = context.eventBus {
                        await eventBus.publishAndTrack(RepositoryChangedEvent(
                            repositoryName: repoName,
                            changeType: .created,
                            entityId: itemId,
                            newValue: item,
                            oldValue: nil
                        ))
                    } else {
                        context.emit(RepositoryChangedEvent(
                            repositoryName: repoName,
                            changeType: .created,
                            entityId: itemId,
                            newValue: item,
                            oldValue: nil
                        ))
                    }
                }
            } else {
                // Single value storage: emit one event (existing behavior)
                let changeType: RepositoryChangeType = storeResult.isUpdate ? .updated : .created

                // Use publishAndTrack to ensure runtime waits for observers to complete
                if let eventBus = context.eventBus {
                    await eventBus.publishAndTrack(RepositoryChangedEvent(
                        repositoryName: repoName,
                        changeType: changeType,
                        entityId: storeResult.entityId,
                        newValue: storeResult.storedValue,
                        oldValue: storeResult.oldValue
                    ))
                } else {
                    context.emit(RepositoryChangedEvent(
                        repositoryName: repoName,
                        changeType: changeType,
                        entityId: storeResult.entityId,
                        newValue: storeResult.storedValue,
                        oldValue: storeResult.oldValue
                    ))
                }
            }
        }

        // Emit store event (legacy)
        context.emit(DataStoredEvent(repository: repoName, dataType: String(describing: type(of: data))))

        return StoreResult(repository: repoName, success: true)
    }
}

/// Writes data to a file with automatic format detection (ARO-0040)
/// The file extension determines the output format:
/// - .json: JSON
/// - .yaml/.yml: YAML
/// - .xml: XML (root element = variable name)
/// - .toml: TOML
/// - .csv: CSV
/// - .tsv: TSV
/// - .md: Markdown table
/// - .html: HTML table
/// - .txt: key=value format
/// - .sql: INSERT statements
/// - .obj/unknown: Binary (pass-through)
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

        // Get file path - check specifiers first (e.g., <file: file-path>), then base
        let path: String
        if let specifier = object.specifiers.first, let resolvedPath: String = context.resolve(specifier) {
            path = resolvedPath
        } else if let resolvedPath: String = context.resolve(object.base) {
            path = resolvedPath
        } else {
            path = object.base
        }

        // Detect format from file extension (ARO-0040)
        let format = FileFormat.detect(from: path)

        // Get format options from "with" clause (ARO-0040)
        // Options can include: delimiter, header, quote, encoding
        var formatOptions: [String: any Sendable] = [:]
        if let configDict = context.resolveAny("_literal_") as? [String: any Sendable] {
            // Check for format options in the literal
            if let delimiter = configDict["delimiter"] as? String {
                formatOptions["delimiter"] = delimiter
            }
            if let header = configDict["header"] as? Bool {
                formatOptions["header"] = header
            }
            if let quote = configDict["quote"] as? String {
                formatOptions["quote"] = quote
            }
            if let encoding = configDict["encoding"] as? String {
                formatOptions["encoding"] = encoding
            }
        }

        // Get data to write - prefer resolveAny to get structured data,
        // only fall back to string if no structured data available
        let content: String
        if let value = context.resolveAny(result.base) {
            // Check if it's a simple string (for binary format passthrough)
            if format == .binary, let strValue = value as? String {
                content = strValue
            } else {
                // Serialize structured data to the detected format
                content = FormatSerializer.serialize(value, format: format, variableName: result.base, options: formatOptions)
            }
        } else {
            content = ""
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

// MARK: - Additional RESPONSE Actions (ARO-0001)

/// Notifies a user or system
public struct NotifyAction: ActionImplementation {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["notify", "alert", "signal"]
    public static let validPrepositions: Set<Preposition> = [.to, .for, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get notification message
        let message: String
        if let value: String = context.resolve(result.base) {
            message = value
        } else if let value = context.resolveAny(result.base) {
            message = String(describing: value)
        } else {
            message = result.fullName
        }

        // Get notification target (e.g., user, system, channel)
        let target = object.base

        // Try notification service
        if let notificationService = context.service(NotificationService.self) {
            try await notificationService.notify(message: message, target: target)
            return NotifyResult(message: message, target: target, success: true)
        }

        // Emit notification event
        context.emit(NotificationSentEvent(message: message, target: target))

        return NotifyResult(message: message, target: target, success: true)
    }
}

/// Notification service protocol
public protocol NotificationService: Sendable {
    func notify(message: String, target: String) async throws
}

/// Result of a notify operation
public struct NotifyResult: Sendable, Equatable {
    public let message: String
    public let target: String
    public let success: Bool
}

/// Event emitted when a notification is sent
public struct NotificationSentEvent: RuntimeEvent {
    public static var eventType: String { "notification.sent" }
    public let timestamp: Date
    public let message: String
    public let target: String

    public init(message: String, target: String) {
        self.timestamp = Date()
        self.message = message
        self.target = target
    }
}

// MARK: - Domain Events

/// A custom domain event emitted by ARO code
/// The eventType is dynamically set based on the event name in the ARO statement
public struct DomainEvent: RuntimeEvent {
    /// The event type (e.g., "UserCreated", "OrderPlaced")
    public let domainEventType: String

    /// Static event type for routing - uses "domain.*" prefix
    public static var eventType: String { "domain" }

    /// Timestamp when the event occurred
    public let timestamp: Date

    /// The payload data attached to the event
    public let payload: [String: any Sendable]

    public init(eventType: String, payload: [String: any Sendable]) {
        self.domainEventType = eventType
        self.timestamp = Date()
        self.payload = payload
    }
}

/// Emits a domain event to trigger event handlers
///
/// The Emit action publishes custom domain events that can be handled
/// by feature sets with matching "Handler" business activity.
///
/// ## Example
/// ```
/// <Emit> a <UserCreated: event> with <user>.
/// ```
/// This triggers feature sets with business activity "UserCreated Handler"
public struct EmitAction: ActionImplementation {
    public static let role: ActionRole = .export
    public static let verbs: Set<String> = ["emit"]
    public static let validPrepositions: Set<Preposition> = [.with, .to]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get event type from result (e.g., "UserCreated" from <UserCreated: event>)
        let eventType = result.base

        // Get payload data from object or literal
        // Always wrap the value with the variable name as key
        // e.g., <Emit> a <UserCreated: event> with <user> -> payload: {"user": <user value>}
        var payload: [String: any Sendable] = [:]

        // Determine the key name for the payload
        // If we have _expression_name_, use it (for variable references like <user>)
        // Otherwise fall back to object.base
        let payloadKey: String
        if let expressionName: String = context.resolve("_expression_name_") {
            payloadKey = expressionName
        } else if object.base != "_expression_" {
            payloadKey = object.base
        } else {
            payloadKey = "data" // Default fallback
        }

        // Check for literal value first (from "with" clause)
        if let literalValue = context.resolveAny("_literal_") {
            payload[payloadKey] = literalValue
        } else if let payloadValue = context.resolveAny(object.base) {
            // Named variable payload - wrap with the payload key
            // This allows handlers to extract with: <Extract> the <user> from the <event: user>
            payload[payloadKey] = payloadValue
        }

        // Create and emit the domain event
        let event = DomainEvent(eventType: eventType, payload: payload)

        print("[EmitAction] Emitting domain event: \(eventType) with payload: \(payload)")

        // Emit to event bus and wait for handlers to complete
        // This ensures event handlers finish before continuing
        if let eventBus = context.eventBus {
            await eventBus.publishAndTrack(event)
        } else {
            // Fallback to fire-and-forget if no event bus
            context.emit(event)
        }

        return EmitResult(eventType: eventType, success: true)
    }
}

/// Result of an emit operation
public struct EmitResult: Sendable, Equatable {
    public let eventType: String
    public let success: Bool
}
