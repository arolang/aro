# ARO-0025: Action Extension Interface

* Proposal: ARO-0025
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0020, ARO-0009

## Abstract

This proposal defines the interface for extending ARO with custom actions, enabling developers to implement domain-specific behaviors that integrate with the runtime.

## Motivation

While ARO provides built-in actions, applications often need:

1. **Domain-Specific Actions**: Custom verbs for specific business domains
2. **External Integrations**: Actions that interact with third-party services
3. **Reusable Components**: Shareable action libraries
4. **Type-Safe Extensions**: Compile-time verification of action implementations

## Proposed Solution

### 1. ActionImplementation Protocol

All actions implement this protocol:

```swift
public protocol ActionImplementation: Sendable {
    /// The semantic role of this action (REQUEST, OWN, RESPONSE, EXPORT)
    static var role: ActionRole { get }

    /// The verbs that trigger this action (e.g., ["Extract", "Get", "Fetch"])
    static var verbs: Set<String> { get }

    /// Valid prepositions for object clauses
    static var validPrepositions: Set<Preposition> { get }

    /// Required initializer
    init()

    /// Execute the action
    func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable
}
```

### 2. Action Roles

Actions are categorized by semantic role (from ARO-0009):

```swift
public enum ActionRole: String, Sendable {
    case request    // Actions that request data from external sources
    case own        // Actions that create/modify owned data
    case response   // Actions that send results/responses
    case export     // Actions that export/publish data
}
```

### 3. Descriptors

Actions receive structured information about the statement:

```swift
public struct ResultDescriptor: Sendable {
    public let base: String           // Variable name to bind
    public let specifiers: [String]   // Type specifiers from qualified noun
    public let span: SourceSpan       // Source location for error reporting

    public var fullName: String       // Full qualified name for display
}

public struct ObjectDescriptor: Sendable {
    public let preposition: Preposition  // for, from, into, with, etc.
    public let base: String              // Source identifier
    public let specifiers: [String]      // Type specifiers from qualified noun
    public let span: SourceSpan          // Source location for error reporting

    public var isExternalReference: Bool // Whether this references an external source
    public var fullName: String          // Full qualified name for display
    public var keyPath: String           // Nested access path (e.g., "request.parameters.userId")
}
```

### 4. Execution Context

Actions access runtime services through the context:

```swift
public protocol ExecutionContext: AnyObject, Sendable {
    // Variable management
    func resolve<T: Sendable>(_ name: String) -> T?
    func resolveAny(_ name: String) -> (any Sendable)?
    func require<T: Sendable>(_ name: String) throws -> T
    func bind(_ name: String, value: any Sendable)
    func exists(_ name: String) -> Bool
    var variableNames: Set<String> { get }

    // Service access
    func service<S>(_ type: S.Type) -> S?
    func register<S: Sendable>(_ service: S)

    // Repository access
    func repository<T: Sendable>(named: String) -> (any Repository<T>)?
    func registerRepository<T: Sendable>(name: String, repository: any Repository<T>)

    // Response management
    func setResponse(_ response: Response)
    func getResponse() -> Response?

    // Event emission
    func emit(_ event: any RuntimeEvent)

    // Metadata
    var featureSetName: String { get }
    var executionId: String { get }
    var parent: ExecutionContext? { get }
    func createChild(featureSetName: String) -> ExecutionContext

    // Wait state management (for long-running applications)
    func enterWaitState()
    func waitForShutdown() async throws
    var isWaiting: Bool { get }
    func signalShutdown()
}
```

### 5. Example: Custom Action Implementation

```swift
/// Custom action to send SMS messages
public struct SendSMSAction: ActionImplementation {
    public static let role: ActionRole = .export
    public static let verbs: Set<String> = ["sms", "text"]
    public static let validPrepositions: Set<Preposition> = [.to, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get the SMS service
        guard let smsService = context.service(SMSService.self) else {
            throw ActionError.missingService("SMSService")
        }

        // Get the message content
        let message: String = try context.require(result.base)

        // Get the recipient from the object
        let recipient: String
        if let resolved: String = context.resolve(object.base) {
            recipient = resolved
        } else {
            recipient = object.base
        }

        // Send the SMS
        let smsResult = try await smsService.send(message: message, to: recipient)

        // Bind result and emit event
        context.bind(result.base, value: smsResult)
        context.emit(SMSSentEvent(recipient: recipient, messageId: smsResult.id))

        return smsResult
    }
}
```

### 6. Registering Custom Actions

```swift
// Register at application startup
let app = Application(programs: [program])

// Register custom action
ActionRegistry.shared.register(SendSMSAction.self)

// Register required service
app.register(service: TwilioSMSService(config: config))

try await app.run()
```

### 7. Using Custom Actions in ARO

```aro
(Send Notification: Alert Handler) {
    <Create> the <message> with "Your order has shipped!".
    <Extract> the <phone> from the <user: phoneNumber>.
    <SMS> the <message> to the <phone>.
    <Return> an <OK: status> for the <notification>.
}
```

---

## Error Handling

Actions should throw `ActionError` for recoverable errors:

```swift
public enum ActionError: Error, Sendable {
    case statementFailed(AROError)           // Generated error from statement (ARO-0008)
    case undefinedVariable(String)           // Variable not found in context
    case propertyNotFound(property: String, on: String)
    case invalidPreposition(action: String, received: Preposition, expected: Set<Preposition>)
    case missingService(String)              // Required service not registered
    case undefinedRepository(String)         // Repository not found
    case typeMismatch(expected: String, actual: String)
    case thrown(type: String, reason: String, context: String)  // Explicit throw
    case unknownAction(String)               // Action not found for verb
    case validationFailed(String)
    case comparisonFailed(String)
    case ioError(String)
    case networkError(String)
    case timeout(String)
    case featureSetNotFound(String)
    case entryPointNotFound(String)
    case cancelled
    case runtimeError(String)
}
```

---

## Best Practices

### 1. Single Responsibility
Each action should do one thing well.

### 2. Fail Fast
Validate inputs early and throw descriptive errors.

### 3. Event Emission
Emit events for significant operations to enable reactive features.

### 4. Service Dependencies
Declare service dependencies clearly; check for their existence.

### 5. Thread Safety
Actions must be `Sendable` and thread-safe.

### 6. Logging
Use the logging service for debugging and monitoring.

---

## Complete Example: Database Action

```swift
/// Action to execute raw SQL queries
public struct QueryAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["query", "sql"]
    public static let validPrepositions: Set<Preposition> = [.from, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get database service
        guard let db = context.service(DatabaseService.self) else {
            throw ActionError.missingService("DatabaseService")
        }

        // Get SQL query - try to resolve as variable, otherwise use as literal
        let sql: String
        if let resolved: String = context.resolve(object.base) {
            sql = resolved
        } else {
            sql = object.base
        }

        // Execute query
        let rows = try await db.query(sql)

        // Bind result
        context.bind(result.base, value: rows)

        // Emit event
        context.emit(QueryExecutedEvent(
            sql: sql,
            rowCount: rows.count,
            executionId: context.executionId
        ))

        return rows
    }
}
```

Usage in ARO:

```aro
(Get Active Users: Database Query) {
    <Create> the <sql> with "SELECT * FROM users WHERE active = true".
    <Query> the <users> from the <sql>.
    <Return> an <OK: status> with <users>.
}
```

---

## Implementation Notes

- Actions are instantiated per-execution (via `init()`)
- The `execute` method must be thread-safe
- Services should be accessed through the context, not stored
- Custom actions integrate with the same event system as built-in actions
- Use `validatePreposition()` helper to check prepositions early
- Verbs should be lowercase in the `verbs` set

---

## Implementation Location

The Action Extension Interface is implemented in:

- `Sources/ARORuntime/Actions/ActionProtocol.swift` - `ActionImplementation` protocol and `ActionRole` enum
- `Sources/ARORuntime/Actions/ActionDescriptors.swift` - `ResultDescriptor` and `ObjectDescriptor`
- `Sources/ARORuntime/Actions/ActionError.swift` - `ActionError` enum
- `Sources/ARORuntime/Actions/ActionRegistry.swift` - `ActionRegistry` for registration
- `Sources/ARORuntime/Core/ExecutionContext.swift` - `ExecutionContext` protocol

See also `Documentation/ActionDeveloperGuide.md` for a comprehensive developer guide.

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-12 | Initial specification |
| 1.1 | 2024-12 | Updated to match implementation: descriptor fields, error cases, context methods |
