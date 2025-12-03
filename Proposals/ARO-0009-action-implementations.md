# ARO-0009: Action Implementations

* Proposal: ARO-0009
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0006, ARO-0008

## Abstract

This proposal defines how ARO action verbs are bound to executable code, enabling specifications to generate working Swift implementations.

## Motivation

ARO describes *what* should happen; this proposal defines *how* it executes:

1. **Execution Model**: How actions run at runtime
2. **Binding Mechanism**: Linking verbs to implementations
3. **Code Generation**: Producing Swift code
4. **Extensibility**: Adding custom actions

## Proposed Solution

A three-layer architecture:

```
┌─────────────────────────────────────────┐
│         ARO Specification           │
│  <Extract> the <user> from <request>.   │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│           Action Registry               │
│    "Extract" → ExtractAction.self       │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│         Swift Implementation            │
│  struct ExtractAction: Action { ... }   │
└─────────────────────────────────────────┘
```

---

### 1. Action Protocol

#### 1.1 Core Protocol

```swift
/// Protocol for all action implementations
public protocol ActionImplementation: Sendable {
    /// Semantic role of this action
    static var role: ActionRole { get }

    /// Verbs that trigger this action (lowercase)
    static var verbs: Set<String> { get }

    /// Valid prepositions for this action
    static var validPrepositions: Set<Preposition> { get }

    /// Default initializer (actions should be stateless)
    init()

    /// Execute the action asynchronously
    func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable
}

public enum ActionRole: String, Sendable, CaseIterable {
    case request    // External → Internal (Extract, Retrieve, Receive)
    case own        // Internal → Internal (Compute, Validate, Compare)
    case response   // Internal → External (Return, Throw, Send)
    case export     // Publish mechanism
}
```

#### 1.2 Descriptors

```swift
/// Describes the result part of an ARO statement
public struct ResultDescriptor: Sendable {
    public let base: String
    public let specifiers: [String]
    public let type: TypeInfo?
    
    public var fullName: String {
        specifiers.isEmpty ? base : "\(base).\(specifiers.joined(separator: "."))"
    }
}

/// Describes the object part of an ARO statement
public struct ObjectDescriptor: Sendable {
    public let preposition: Preposition
    public let base: String
    public let specifiers: [String]
    public let type: TypeInfo?
}
```

---

### 2. Execution Context

#### 2.1 Context Protocol

```swift
/// Runtime context for action execution
public protocol ExecutionContext: AnyObject, Sendable {
    // Variable access
    func resolve<T>(_ name: String) -> T?
    func bind(_ name: String, to value: Any)
    
    // Services
    func service<S>(_ type: S.Type) -> S?
    
    // Repositories
    func repository<T>(named: String) -> Repository<T>?
    
    // Computations
    func compute(_ name: String, input: Any) throws -> Any
    
    // Response
    func setResponse(_ response: Response)
    func getResponse() -> Response?
    
    // Metadata
    var featureSetName: String { get }
    var executionId: String { get }
}
```

#### 2.2 Concrete Implementation

```swift
public final class RuntimeContext: ExecutionContext, @unchecked Sendable {
    private var variables: [String: Any] = [:]
    private var services: [ObjectIdentifier: Any] = [:]
    private var repositories: [String: Any] = [:]
    private var computations: [String: (Any) throws -> Any] = [:]
    private var response: Response?
    
    public let featureSetName: String
    public let executionId: String
    
    private let lock = NSLock()
    
    public init(featureSetName: String) {
        self.featureSetName = featureSetName
        self.executionId = UUID().uuidString
    }
    
    public func resolve<T>(_ name: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return variables[name] as? T
    }
    
    public func bind(_ name: String, to value: Any) {
        lock.lock()
        defer { lock.unlock() }
        variables[name] = value
    }
    
    public func register<S>(_ service: S) {
        lock.lock()
        defer { lock.unlock() }
        services[ObjectIdentifier(S.self)] = service
    }
    
    public func service<S>(_ type: S.Type) -> S? {
        lock.lock()
        defer { lock.unlock() }
        return services[ObjectIdentifier(type)] as? S
    }
    
    // ... other implementations
}
```

---

### 3. Built-in Actions

ARO implements 24 built-in actions across four semantic roles:

#### 3.1 REQUEST Actions (External → Internal)

| Action | Verbs | Prepositions | Description |
|--------|-------|--------------|-------------|
| **Extract** | extract | from, via | Extract values from objects/structures |
| **Retrieve** | retrieve | from | Retrieve data from repositories |
| **Receive** | receive | from, via | Receive data from external sources |
| **Fetch** | fetch | from | Fetch data from HTTP endpoints |
| **Read** | read | from | Read data from files |

```swift
/// Example: ExtractAction
public struct ExtractAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["extract"]
    public static let validPrepositions: Set<Preposition> = [.from, .via]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Get source object and extract value using specifiers as key path
        guard let source = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }
        let extracted = try extractValue(from: source, specifiers: object.specifiers)
        context.bind(result.base, value: extracted)
        return extracted
    }
}
```

#### 3.2 OWN Actions (Internal → Internal)

| Action | Verbs | Prepositions | Description |
|--------|-------|--------------|-------------|
| **Compute** | compute, calculate, derive | from, for, with | Compute values |
| **Validate** | validate, check, verify | for, against | Validate data |
| **Compare** | compare | against, to, with | Compare values |
| **Transform** | transform, convert | to, into | Transform data |
| **Create** | create, make, build | with, from | Create new entities |
| **Update** | update, modify, change | with, to | Update existing entities |
| **Filter** | filter | from, by, where | Filter collections |
| **Sort** | sort, order | by | Sort collections |
| **Merge** | merge, combine | with, into | Merge collections |
| **Delete** | delete, remove | from | Delete entities |

```swift
/// Example: ComputeAction
public struct ComputeAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["compute", "calculate", "derive"]
    public static let validPrepositions: Set<Preposition> = [.from, .for, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Get input and compute result based on specifiers
        guard let input = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }
        let computed = try compute(operation: result.specifiers, input: input)
        context.bind(result.base, value: computed)
        return computed
    }
}
```

#### 3.3 RESPONSE Actions (Internal → External)

| Action | Verbs | Prepositions | Description |
|--------|-------|--------------|-------------|
| **Return** | return | for, with | Return response |
| **Throw** | throw | for | Throw error |
| **Send** | send | to, via | Send data externally |
| **Log** | log, print | for, to | Log messages |
| **Store** | store, save, persist | in, to | Store data |
| **Write** | write | to | Write to files |
| **Notify** | notify, alert | for | Send notifications |

```swift
/// Example: ReturnAction
public struct ReturnAction: ActionImplementation {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["return"]
    public static let validPrepositions: Set<Preposition> = [.for, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        let response = Response(
            status: result.base,
            reason: object.base,
            data: gatherResponseData(context: context)
        )
        context.setResponse(response)
        return response
    }
}
```

#### 3.4 EXPORT Actions

| Action | Verbs | Prepositions | Description |
|--------|-------|--------------|-------------|
| **Publish** | publish | as | Publish variables globally |

#### 3.5 SERVER Actions

| Action | Verbs | Prepositions | Description |
|--------|-------|--------------|-------------|
| **Start** | start | on | Start services (HTTP, Socket) |
| **Listen** | listen | on | Listen on ports |
| **Route** | route | to | Configure routes |
| **Watch** | watch | for | Watch files/directories |
| **Keepalive** | keepalive, wait | for | Keep application running |

---

### 4. Action Registry

```swift
/// Global registry that binds action verbs to their implementations
public final class ActionRegistry: @unchecked Sendable {
    public static let shared = ActionRegistry()

    private let lock = NSLock()
    private var actions: [String: any ActionImplementation.Type] = [:]

    private init() {
        registerBuiltIns()
    }

    private func registerBuiltIns() {
        // REQUEST actions
        register(ExtractAction.self)
        register(RetrieveAction.self)
        register(ReceiveAction.self)
        register(FetchAction.self)
        register(ReadAction.self)

        // OWN actions
        register(ComputeAction.self)
        register(ValidateAction.self)
        register(CompareAction.self)
        register(TransformAction.self)
        register(CreateAction.self)
        register(UpdateAction.self)
        register(FilterAction.self)
        register(SortAction.self)
        register(MergeAction.self)
        register(DeleteAction.self)

        // RESPONSE actions
        register(ReturnAction.self)
        register(ThrowAction.self)
        register(SendAction.self)
        register(LogAction.self)
        register(StoreAction.self)
        register(WriteAction.self)
        register(NotifyAction.self)

        // EXPORT actions
        register(PublishAction.self)

        // SERVER actions
        register(StartAction.self)
        register(ListenAction.self)
        register(RouteAction.self)
        register(WatchAction.self)
        register(WaitForEventsAction.self)
    }

    public func register<A: ActionImplementation>(_ action: A.Type) {
        lock.lock()
        defer { lock.unlock() }
        for verb in A.verbs {
            actions[verb.lowercased()] = action
        }
    }

    public func action(for verb: String) -> (any ActionImplementation)? {
        lock.lock()
        defer { lock.unlock() }
        guard let actionType = actions[verb.lowercased()] else {
            return nil
        }
        return actionType.init()
    }
}
```

---

### 5. Custom Actions

#### 5.1 In ARO Syntax

```ebnf
action_definition = "action" , action_name , 
                    "(" , param_list , ")" , 
                    [ "->" , return_type ] ,
                    block ;
```

**Example:**
```
// Define custom action
action SendEmail(recipient: String, subject: String, body: String) -> Bool {
    <Validate> the <recipient: format> for the <email-pattern>.
    <Compose> the <message> with { 
        to: <recipient>, 
        subject: <subject>, 
        body: <body> 
    }.
    <Dispatch> the <message> via the <smtp-service>.
    <Return> the <success: status> for the <dispatch>.
}

// Use custom action
(Notification: Communication) {
    <SendEmail> the <welcome-email> to the <user: email> with {
        subject: "Welcome!",
        body: <welcome-template>
    }.
}
```

#### 5.2 In Swift

```swift
// Define custom action in Swift
public struct SendEmailAction: ActionImplementation {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["sendemail", "email"]
    public static let validPrepositions: Set<Preposition> = [.to, .via]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        guard let emailService = context.service(EmailService.self) else {
            throw ActionError.missingService("EmailService")
        }

        let recipient: String = try context.require(object.base)

        let email = Email(
            to: recipient,
            subject: result.specifiers.first ?? "No Subject",
            body: result.specifiers.dropFirst().first ?? ""
        )

        let success = try await emailService.send(email)
        context.bind(result.base, value: success)
        return success
    }
}

// Register
ActionRegistry.shared.register(SendEmailAction.self)
```

---

### 6. Code Generation

#### 6.1 Generated Feature Set

From this specification:

```
(User Authentication: Security) {
    <Extract> the <user: identifier> from the <request: parameters>.
    <Retrieve> the <user: record> from the <user-repository>.
    <Compute> the <password: hash> for the <credentials>.
    <Return> an <OK: status> for a <valid: authentication>.
}
```

Generate:

```swift
// GENERATED CODE - DO NOT EDIT

import ARORuntime

public struct UserAuthentication: FeatureSet {
    public static let name = "User Authentication"
    public static let businessActivity = "Security"

    public init() {}

    public func execute(context: ExecutionContext) async throws -> Response {
        // <Extract> the <user: identifier> from the <request: parameters>
        _ = try await ActionRegistry.shared
            .action(for: "Extract")!
            .execute(
                result: ResultDescriptor(base: "user", specifiers: ["identifier"]),
                object: ObjectDescriptor(
                    preposition: .from,
                    base: "request",
                    specifiers: ["parameters"]
                ),
                context: context
            )
        // Result bound to "user" by action

        // <Retrieve> the <user: record> from the <user-repository>
        _ = try await ActionRegistry.shared
            .action(for: "Retrieve")!
            .execute(
                result: ResultDescriptor(base: "user", specifiers: ["record"]),
                object: ObjectDescriptor(
                    preposition: .from,
                    base: "user-repository",
                    specifiers: []
                ),
                context: context
            )
        // Result bound to "user" by action

        // <Compute> the <password: hash> for the <credentials>
        _ = try await ActionRegistry.shared
            .action(for: "Compute")!
            .execute(
                result: ResultDescriptor(base: "password", specifiers: ["hash"]),
                object: ObjectDescriptor(
                    preposition: .for,
                    base: "credentials",
                    specifiers: []
                ),
                context: context
            )
        // Result bound to "password" by action

        // <Return> an <OK: status> for a <valid: authentication>
        let response = try await ActionRegistry.shared
            .action(for: "Return")!
            .execute(
                result: ResultDescriptor(base: "OK", specifiers: ["status"]),
                object: ObjectDescriptor(
                    preposition: .for,
                    base: "valid",
                    specifiers: ["authentication"]
                ),
                context: context
            ) as! Response

        return response
    }
}
```

#### 6.2 With Type Safety

If types are specified:

```swift
public struct UserAuthentication: FeatureSet {
    public func execute(context: ExecutionContext) async throws -> Response {
        // Type-safe extraction
        let user: User = try await context.extract(
            \.identifier,
            from: "request.parameters"
        )
        
        // Type-safe retrieval
        let userRecord: UserRecord = try await context.retrieve(
            from: context.repository(for: UserRecord.self),
            matching: \.id == user.id
        )
        
        // Type-safe computation
        let passwordHash: String = try await context.compute(
            .hash,
            input: context.resolve("credentials")
        )
        
        return Response.ok(user: userRecord)
    }
}
```

---

### 7. Integration Patterns

#### 7.1 Vapor Integration

```swift
import Vapor
import ARORuntime

func routes(_ app: Application) throws {
    app.post("login") { req async throws -> Response in
        let context = RuntimeContext(featureSetName: "UserAuthentication")
        
        // Bind Vapor request
        context.bind("request", to: VaporRequestAdapter(req))
        
        // Register services
        context.register(app.db as DatabaseService)
        context.register(app.jwt as JWTService)
        
        // Execute feature
        let feature = UserAuthentication()
        let response = try await feature.execute(context: context)
        
        return response.toVapor()
    }
}
```

#### 7.2 SwiftUI Integration

```swift
import SwiftUI
import ARORuntime

@Observable
class AuthViewModel {
    @Feature private var auth: UserAuthentication
    
    var isLoading = false
    var error: Error?
    
    func login(email: String, password: String) async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let context = RuntimeContext(featureSetName: "Login")
            context.bind("request", to: LoginRequest(email: email, password: password))
            
            let response = try await auth.execute(context: context)
            // Handle response
        } catch {
            self.error = error
        }
    }
}
```

---

### 8. Action Lifecycle

```
┌──────────────────────────────────────────────────────────────┐
│                     Action Execution                         │
├──────────────────────────────────────────────────────────────┤
│  1. Parse ARO Statement                                      │
│     └─ Extract: Action, Result, Object                       │
│                                                              │
│  2. Resolve Action                                           │
│     └─ ActionRegistry.action(for: verb)                      │
│                                                              │
│  3. Validate Preposition                                     │
│     └─ Check: object.preposition ∈ Action.prepositions       │
│                                                              │
│  4. Resolve Dependencies                                     │
│     └─ Context.resolve(object.base)                          │
│                                                              │
│  5. Execute Action                                           │
│     └─ action.execute(result, object, context)               │
│                                                              │
│  6. Bind Result                                              │
│     └─ Context.bind(result.base, value)                      │
│                                                              │
│  7. Continue or Return                                       │
│     └─ Next statement or response                            │
└──────────────────────────────────────────────────────────────┘
```

---

### 9. Complete Grammar Extension

```ebnf
(* Action Definition *)
action_definition = "action" , identifier , 
                    "(" , [ parameter_list ] , ")" ,
                    [ "->" , type_annotation ] ,
                    block ;

parameter_list = parameter , { "," , parameter } ;
parameter = identifier , ":" , type_annotation ;

(* Action Annotation *)
action_annotation = "@action" , "(" , 
                    "verbs" , ":" , string_list ,
                    "," , "prepositions" , ":" , preposition_list ,
                    ")" ;

string_list = "[" , string_literal , { "," , string_literal } , "]" ;
preposition_list = "[" , preposition , { "," , preposition } , "]" ;
```

---

### 10. Complete Example

```
// actions.aro - Custom action definitions

action ValidateEmail(email: String) -> ValidationResult {
    <Check> the <format> for the <email> against "^[^@]+@[^@]+$".
    
    if <format> is not <valid> then {
        <Return> a <Invalid: ValidationResult> with {
            field: "email",
            reason: "Invalid email format"
        }.
    }
    
    <Check> the <domain: mx-record> for the <email>.
    
    if <domain: mx-record> is not <found> then {
        <Return> a <Invalid: ValidationResult> with {
            field: "email", 
            reason: "Email domain not found"
        }.
    }
    
    <Return> a <Valid: ValidationResult> for the <email>.
}

// usage.aro
(User Registration: Onboarding) {
    <Extract> the <email: String> from the <request: body>.
    <Extract> the <password: String> from the <request: body>.
    
    // Use custom action
    <ValidateEmail> the <result: ValidationResult> for the <email>.
    
    if <result> is not <valid> then {
        <Return> a <BadRequest> with <result>.reason.
    }
    
    <Hash> the <password-hash> from the <password>.
    <Create> the <user> with {
        email: <email>,
        passwordHash: <password-hash>
    }.
    
    <Store> the <user> in the <user-repository>.
    <Return> an <OK> with <user>.
}
```

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
