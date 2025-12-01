# ARO-0025: Action Extension Interface

* Proposal: ARO-0025
* Author: ARO Language Team
* Status: **Draft**
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
    public let identifier: String      // Variable name to bind
    public let typeHint: String?       // Optional type annotation
    public let article: String         // "a", "an", "the"
}

public struct ObjectDescriptor: Sendable {
    public let preposition: Preposition  // for, from, into, with, etc.
    public let sourceType: SourceType    // variable, literal, repository, etc.
    public let identifier: String        // Source identifier
    public let qualifier: String?        // Optional qualifier after ':'
    public let condition: Condition?     // Optional where clause
}
```

### 4. Execution Context

Actions access runtime services through the context:

```swift
public protocol ExecutionContext: AnyObject, Sendable {
    // Variable management
    func resolve<T: Sendable>(_ name: String) -> T?
    func require<T: Sendable>(_ name: String) throws -> T
    func bind(_ name: String, value: any Sendable)
    func exists(_ name: String) -> Bool

    // Service access
    func service<S>(_ type: S.Type) -> S?

    // Repository access
    func repository<T>(named: String) -> (any Repository<T>)?

    // Response management
    func setResponse(_ response: Response)
    func getResponse() -> Response?

    // Event emission
    func emit(_ event: any RuntimeEvent)

    // Metadata
    var featureSetName: String { get }
    var executionId: String { get }
}
```

### 5. Example: Custom Action Implementation

```swift
/// Custom action to send SMS messages
public struct SendSMSAction: ActionImplementation {
    public static let role: ActionRole = .export
    public static let verbs: Set<String> = ["SMS", "Text"]
    public static let validPrepositions: Set<Preposition> = [.to, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Get the SMS service
        guard let smsService = context.service(SMSService.self) else {
            throw ActionError.serviceNotFound("SMSService")
        }

        // Get the message content
        let message: String = try context.require(result.identifier)

        // Get the recipient from the object
        let recipient: String
        switch object.sourceType {
        case .variable:
            recipient = try context.require(object.identifier)
        case .literal:
            recipient = object.identifier
        default:
            throw ActionError.invalidObjectSource(object.sourceType)
        }

        // Send the SMS
        let result = try await smsService.send(message: message, to: recipient)

        // Emit event
        context.emit(SMSSentEvent(recipient: recipient, messageId: result.id))

        return result
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
    case variableNotFound(String)
    case typeMismatch(expected: String, actual: String)
    case serviceNotFound(String)
    case repositoryNotFound(String)
    case invalidObjectSource(SourceType)
    case conditionNotMet(String)
    case executionFailed(String)
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
    public static let verbs: Set<String> = ["Query", "SQL"]
    public static let validPrepositions: Set<Preposition> = [.from, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Get database service
        guard let db = context.service(DatabaseService.self) else {
            throw ActionError.serviceNotFound("DatabaseService")
        }

        // Get SQL query
        let sql: String
        switch object.sourceType {
        case .variable:
            sql = try context.require(object.identifier)
        case .literal:
            sql = object.identifier
        default:
            throw ActionError.invalidObjectSource(object.sourceType)
        }

        // Execute query
        let rows = try await db.query(sql)

        // Bind result
        context.bind(result.identifier, value: rows)

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

- Actions are instantiated once and reused
- The `execute` method must be thread-safe
- Services should be accessed through the context, not stored
- Custom actions integrate with the same event system as built-in actions

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-12 | Initial specification |
