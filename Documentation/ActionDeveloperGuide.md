# Action Developer Guide

This guide explains how to extend ARO with custom actions. Actions are the fundamental building blocks that implement ARO verbs like `<Extract>`, `<Create>`, `<Return>`, etc.

## Table of Contents

1. [Understanding Actions](#understanding-actions)
2. [The ActionImplementation Protocol](#the-actionimplementation-protocol)
3. [Action Roles](#action-roles)
4. [Descriptors](#descriptors)
5. [Execution Context](#execution-context)
6. [Step-by-Step: Creating a Custom Action](#step-by-step-creating-a-custom-action)
7. [Best Practices](#best-practices)
8. [Examples](#examples)
9. [Testing Actions](#testing-actions)
10. [Troubleshooting](#troubleshooting)

---

## Understanding Actions

In ARO, every statement follows the Action-Result-Object pattern:

```aro
<Verb> the <result> from/to/with/for the <object>.
```

For example:
```aro
<Extract> the <user-id> from the <request: parameters>.
<Create> the <user> with <user-data>.
<Return> an <OK: status> with <response>.
```

Each verb maps to an action implementation that:
1. Receives structured information about the statement
2. Executes business logic
3. Returns a result to be bound to a variable

---

## The ActionImplementation Protocol

```swift
public protocol ActionImplementation: Sendable {
    /// The semantic role of this action
    static var role: ActionRole { get }

    /// The verbs that trigger this action
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

### Key Points

- **Sendable**: Actions must be thread-safe
- **Static properties**: Define metadata at compile time
- **Async/throws**: Actions can be async and may throw errors
- **Returns `any Sendable`**: Results must be sendable across concurrency domains

---

## Action Roles

Actions are categorized by semantic role:

| Role | Description | Example Verbs |
|------|-------------|---------------|
| `request` | Request data from external sources | Extract, Retrieve, Fetch, Query |
| `own` | Create or modify owned data | Create, Compute, Transform, Validate |
| `response` | Send results or responses | Return, Respond, Reply |
| `export` | Export or publish data | Store, Publish, Log, Send |

```swift
public enum ActionRole: String, Sendable {
    case request
    case own
    case response
    case export
}
```

Choose the role that best describes your action's primary purpose.

---

## Descriptors

### ResultDescriptor

Information about the result variable:

```swift
public struct ResultDescriptor: Sendable {
    public let identifier: String   // Variable name to bind (e.g., "user-id")
    public let typeHint: String?    // Optional type (e.g., "JSON")
    public let article: String      // "a", "an", or "the"
}
```

### ObjectDescriptor

Information about the object clause:

```swift
public struct ObjectDescriptor: Sendable {
    public let preposition: Preposition   // from, to, into, with, for
    public let sourceType: SourceType     // variable, literal, repository, etc.
    public let identifier: String         // Source identifier
    public let qualifier: String?         // Qualifier after ":" (e.g., "body" in "request: body")
    public let condition: Condition?      // Optional where clause
}
```

### Source Types

```swift
public enum SourceType: String, Sendable {
    case variable       // Reference to a bound variable
    case literal        // Literal string value
    case repository     // Repository reference
    case service        // Service reference
    case event          // Event data reference
    case request        // HTTP request data
    case file           // File reference
}
```

### Prepositions

```swift
public enum Preposition: String, Sendable {
    case from     // Source of data
    case to       // Destination for data
    case into     // Storage target
    case with     // Additional data/parameters
    case forPrep  // Purpose or target
    case via      // Method or channel
    case at       // Location reference
    case on       // Target for operations
}
```

---

## Execution Context

The `ExecutionContext` provides access to runtime services:

```swift
public protocol ExecutionContext: AnyObject, Sendable {
    // Variable Management
    func resolve<T: Sendable>(_ name: String) -> T?
    func require<T: Sendable>(_ name: String) throws -> T
    func bind(_ name: String, value: any Sendable)
    func exists(_ name: String) -> Bool

    // Service Access
    func service<S>(_ type: S.Type) -> S?

    // Repository Access
    func repository<T>(named: String) -> (any Repository<T>)?

    // Response Management
    func setResponse(_ response: Response)
    func getResponse() -> Response?

    // Event Emission
    func emit(_ event: any RuntimeEvent)

    // Metadata
    var featureSetName: String { get }
    var executionId: String { get }
}
```

### Variable Operations

```swift
// Get optional value
let name: String? = context.resolve("user-name")

// Get required value (throws if not found)
let userId: String = try context.require("user-id")

// Bind a new variable
context.bind("result", value: computedValue)

// Check existence
if context.exists("optional-param") {
    // ...
}
```

### Service Access

```swift
// Get a registered service
guard let httpClient = context.service(HTTPClientService.self) else {
    throw ActionError.serviceNotFound("HTTPClientService")
}
```

### Event Emission

```swift
// Emit domain events
context.emit(UserCreatedEvent(userId: newUser.id))
```

---

## Step-by-Step: Creating a Custom Action

### Step 1: Define Your Action

```swift
import ARORuntime

public struct EmailAction: ActionImplementation {
    // 1. Define the semantic role
    public static let role: ActionRole = .export

    // 2. Define verbs that trigger this action
    public static let verbs: Set<String> = ["Email", "Mail"]

    // 3. Define valid prepositions
    public static let validPrepositions: Set<Preposition> = [.to, .with]

    // 4. Required initializer
    public init() {}

    // 5. Implement execute
    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Implementation here
    }
}
```

### Step 2: Implement the Execute Method

```swift
public func execute(
    result: ResultDescriptor,
    object: ObjectDescriptor,
    context: ExecutionContext
) async throws -> any Sendable {
    // Get required service
    guard let emailService = context.service(EmailService.self) else {
        throw ActionError.serviceNotFound("EmailService")
    }

    // Get the email content (from result identifier)
    let content: EmailContent = try context.require(result.identifier)

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

    // Perform the action
    let sendResult = try await emailService.send(
        content: content,
        to: recipient
    )

    // Emit event for observability
    context.emit(EmailSentEvent(
        recipient: recipient,
        messageId: sendResult.messageId
    ))

    // Return the result
    return sendResult
}
```

### Step 3: Register Your Action

```swift
// In your application setup
ActionRegistry.shared.register(EmailAction.self)
```

### Step 4: Use in ARO

```aro
(Send Welcome Email: User Onboarding) {
    <Create> the <email-content> with {
        subject: "Welcome to our platform!",
        body: "Thanks for signing up..."
    }.
    <Extract> the <user-email> from the <user: email>.
    <Email> the <email-content> to the <user-email>.
    <Return> an <OK: status> for the <email>.
}
```

---

## Best Practices

### 1. Single Responsibility

Each action should do one thing well:

```swift
// Good: Focused action
public struct HashPasswordAction: ActionImplementation { ... }

// Bad: Action doing too much
public struct UserManagementAction: ActionImplementation { ... }
```

### 2. Fail Fast with Descriptive Errors

Validate inputs early:

```swift
public func execute(...) async throws -> any Sendable {
    // Validate required services
    guard let service = context.service(MyService.self) else {
        throw ActionError.serviceNotFound("MyService")
    }

    // Validate required variables
    let input: InputType = try context.require(result.identifier)

    // Validate preposition
    guard Self.validPrepositions.contains(object.preposition) else {
        throw ActionError.executionFailed(
            "Invalid preposition '\(object.preposition)' for \(Self.verbs.first ?? "action")"
        )
    }

    // ... proceed with execution
}
```

### 3. Use Strong Types

Leverage Swift's type system:

```swift
// Define domain types
public struct EmailContent: Sendable {
    let subject: String
    let body: String
    let attachments: [Attachment]
}

// Use in action
let content: EmailContent = try context.require(result.identifier)
```

### 4. Emit Events for Observability

```swift
// Emit events for significant operations
context.emit(PaymentProcessedEvent(
    amount: amount,
    currency: currency,
    transactionId: result.id
))
```

### 5. Handle Cleanup

For actions that allocate resources:

```swift
public func execute(...) async throws -> any Sendable {
    let connection = try await openConnection()
    defer { connection.close() }

    return try await connection.execute(query)
}
```

### 6. Document Your Action

```swift
/// Sends an email using the configured email service.
///
/// Usage in ARO:
/// ```aro
/// <Email> the <content> to the <recipient>.
/// ```
///
/// Requirements:
/// - EmailService must be registered
/// - Result must be EmailContent type
/// - Object must be a string (email address)
public struct EmailAction: ActionImplementation { ... }
```

---

## Examples

### Example 1: Data Transformation Action

```swift
public struct ParseJSONAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["Parse", "Decode"]
    public static let validPrepositions: Set<Preposition> = [.from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Get source string
        let jsonString: String = try context.require(object.identifier)

        // Parse JSON
        guard let data = jsonString.data(using: .utf8) else {
            throw ActionError.executionFailed("Invalid UTF-8 string")
        }

        let parsed = try JSONSerialization.jsonObject(with: data)

        // Bind result
        context.bind(result.identifier, value: parsed)

        return parsed
    }
}
```

Usage:
```aro
<Parse> the <config> from the <json-string>.
```

### Example 2: External API Action

```swift
public struct WeatherAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["Weather", "Forecast"]
    public static let validPrepositions: Set<Preposition> = [.forPrep]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        guard let httpClient = context.service(HTTPClientService.self) else {
            throw ActionError.serviceNotFound("HTTPClientService")
        }

        // Get city from object
        let city: String
        switch object.sourceType {
        case .variable:
            city = try context.require(object.identifier)
        case .literal:
            city = object.identifier
        default:
            throw ActionError.invalidObjectSource(object.sourceType)
        }

        // Make API call
        let url = "https://api.weather.com/v1/forecast?city=\(city)"
        let response = try await httpClient.get(url: url)

        // Bind and return
        context.bind(result.identifier, value: response)
        return response
    }
}
```

Usage:
```aro
<Weather> the <forecast> for the <city>.
```

### Example 3: Repository Action

```swift
public struct FindAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["Find", "Lookup"]
    public static let validPrepositions: Set<Preposition> = [.from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Get repository
        guard let repo: any Repository<Any> = context.repository(
            named: object.identifier
        ) else {
            throw ActionError.repositoryNotFound(object.identifier)
        }

        // Apply condition if present
        let items: [Any]
        if let condition = object.condition {
            items = try await repo.find(where: condition)
        } else {
            items = try await repo.findAll()
        }

        context.bind(result.identifier, value: items)
        return items
    }
}
```

Usage:
```aro
<Find> the <users> from the <user-repository> where status = "active".
```

---

## Testing Actions

### Unit Testing

```swift
import XCTest
@testable import ARORuntime

final class EmailActionTests: XCTestCase {
    var mockContext: MockExecutionContext!
    var mockEmailService: MockEmailService!

    override func setUp() {
        mockEmailService = MockEmailService()
        mockContext = MockExecutionContext()
        mockContext.registerService(mockEmailService)
    }

    func testSendsEmail() async throws {
        // Arrange
        let content = EmailContent(subject: "Test", body: "Hello")
        mockContext.bind("email-content", value: content)

        let result = ResultDescriptor(
            identifier: "email-content",
            typeHint: nil,
            article: "the"
        )
        let object = ObjectDescriptor(
            preposition: .to,
            sourceType: .literal,
            identifier: "test@example.com",
            qualifier: nil,
            condition: nil
        )

        // Act
        let action = EmailAction()
        _ = try await action.execute(
            result: result,
            object: object,
            context: mockContext
        )

        // Assert
        XCTAssertEqual(mockEmailService.sentEmails.count, 1)
        XCTAssertEqual(mockEmailService.sentEmails[0].recipient, "test@example.com")
    }

    func testThrowsWhenServiceMissing() async {
        // Arrange
        mockContext = MockExecutionContext() // No service registered

        let result = ResultDescriptor(identifier: "content", typeHint: nil, article: "the")
        let object = ObjectDescriptor(
            preposition: .to,
            sourceType: .literal,
            identifier: "test@example.com",
            qualifier: nil,
            condition: nil
        )

        // Act & Assert
        let action = EmailAction()
        await XCTAssertThrowsError(
            try await action.execute(result: result, object: object, context: mockContext)
        ) { error in
            XCTAssertEqual(error as? ActionError, .serviceNotFound("EmailService"))
        }
    }
}
```

### Integration Testing

```swift
func testEmailActionIntegration() async throws {
    // Setup real application
    let app = Application(programs: [])
    app.register(service: RealEmailService(config: testConfig))
    ActionRegistry.shared.register(EmailAction.self)

    // Execute feature set that uses email action
    let program = try compile("""
        (Send Test Email: Test) {
            <Create> the <content> with { subject: "Test", body: "Hello" }.
            <Email> the <content> to "test@example.com".
            <Return> an <OK: status> for the <email>.
        }
    """)

    let result = try await app.execute(featureSet: "Send Test Email", from: program)
    XCTAssertEqual(result.status, .ok)
}
```

---

## Troubleshooting

### Common Issues

**Action not found**
```
Error: No action registered for verb 'MyVerb'
```
Solution: Ensure you've called `ActionRegistry.shared.register(MyAction.self)`

**Service not found**
```
Error: Service 'MyService' not found in context
```
Solution: Register the service with the application before running

**Variable not found**
```
Error: Variable 'my-var' not found in context
```
Solution: Ensure the variable is bound before accessing it

**Type mismatch**
```
Error: Expected 'String' but found 'Int'
```
Solution: Check that bound values match expected types

### Debugging Tips

1. **Enable logging**: Add logging to your action's execute method
2. **Check registration order**: Services must be registered before actions that use them
3. **Inspect context state**: Print bound variables during development
4. **Use breakpoints**: Set breakpoints in execute() to inspect runtime state

---

## Summary

Creating custom actions involves:

1. Implementing `ActionImplementation` protocol
2. Defining role, verbs, and valid prepositions
3. Implementing async `execute` method
4. Registering with `ActionRegistry`
5. Using in ARO code with the defined verbs

Follow best practices for maintainable, testable actions that integrate well with the ARO runtime.
