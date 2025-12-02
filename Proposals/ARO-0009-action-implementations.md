# ARO-0009: Action Implementations

* Proposal: ARO-0009
* Author: ARO Language Team
* Status: **Draft**
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
public protocol Action: Sendable {
    /// Semantic role of this action
    static var semanticRole: ActionRole { get }
    
    /// Verbs that trigger this action
    static var verbs: Set<String> { get }
    
    /// Compatible prepositions
    static var prepositions: Set<Preposition> { get }
    
    /// Execute the action
    func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> Any
}

public enum ActionRole: Sendable {
    case request    // External → Internal
    case own        // Internal → Internal
    case response   // Internal → External
    case export     // Publish
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

#### 3.1 Extract Action

```swift
/// Extracts a value from a source
public struct ExtractAction: Action {
    public static let semanticRole: ActionRole = .request
    public static let verbs: Set<String> = ["extract", "parse", "get"]
    public static let prepositions: Set<Preposition> = [.from, .via]
    
    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> Any {
        // Get source object
        guard let source: Any = context.resolve(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }
        
        // Build key path from specifiers
        let keyPath = object.specifiers.joined(separator: ".")
        
        // Extract value
        return try extractValue(from: source, path: keyPath)
    }
    
    private func extractValue(from source: Any, path: String) throws -> Any {
        // Mirror-based extraction for dynamic access
        var current: Any = source
        
        for key in path.split(separator: ".").map(String.init) {
            let mirror = Mirror(reflecting: current)
            guard let child = mirror.children.first(where: { $0.label == key }) else {
                throw ActionError.propertyNotFound(key, in: String(describing: type(of: current)))
            }
            current = child.value
        }
        
        return current
    }
}
```

#### 3.2 Retrieve Action

```swift
/// Retrieves data from a repository
public struct RetrieveAction: Action {
    public static let semanticRole: ActionRole = .request
    public static let verbs: Set<String> = ["retrieve", "fetch", "load", "find"]
    public static let prepositions: Set<Preposition> = [.from]
    
    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> Any {
        // Get repository name
        let repoName = object.base
        
        guard let repository = context.repository(named: repoName) else {
            throw ActionError.undefinedRepository(repoName)
        }
        
        // Build query from result specifiers
        let query = Query(type: result.base, fields: result.specifiers)
        
        return try await repository.find(query)
    }
}
```

#### 3.3 Compute Action

```swift
/// Computes a value from inputs
public struct ComputeAction: Action {
    public static let semanticRole: ActionRole = .own
    public static let verbs: Set<String> = ["compute", "calculate", "derive"]
    public static let prepositions: Set<Preposition> = [.from, .for, .with]
    
    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> Any {
        // Get computation name from result specifiers
        let computationName = result.specifiers.first ?? "identity"
        
        // Get input
        guard let input: Any = context.resolve(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }
        
        // Execute computation
        return try context.compute(computationName, input: input)
    }
}
```

#### 3.4 Return Action

```swift
/// Returns a response
public struct ReturnAction: Action {
    public static let semanticRole: ActionRole = .response
    public static let verbs: Set<String> = ["return", "respond", "send"]
    public static let prepositions: Set<Preposition> = [.for, .to, .with]
    
    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> Any {
        let statusName = result.base
        let reason = object.base
        
        let response = Response(
            status: statusName,
            reason: reason,
            data: gatherResponseData(context: context)
        )
        
        context.setResponse(response)
        return response
    }
}
```

#### 3.5 Throw Action

```swift
/// Throws an error
public struct ThrowAction: Action {
    public static let semanticRole: ActionRole = .response
    public static let verbs: Set<String> = ["throw", "raise", "fail"]
    public static let prepositions: Set<Preposition> = [.for]
    
    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> Any {
        let errorType = result.base
        let reason = object.base
        
        throw ActionError.thrown(
            type: errorType,
            reason: reason,
            context: context.featureSetName
        )
    }
}
```

---

### 4. Action Registry

```swift
/// Global registry of actions
@MainActor
public final class ActionRegistry {
    public static let shared = ActionRegistry()
    
    private var actions: [String: any Action.Type] = [:]
    
    private init() {
        registerBuiltins()
    }
    
    private func registerBuiltins() {
        register(ExtractAction.self)
        register(RetrieveAction.self)
        register(ComputeAction.self)
        register(ReturnAction.self)
        register(ThrowAction.self)
        register(ValidateAction.self)
        register(CompareAction.self)
        register(CreateAction.self)
        register(UpdateAction.self)
        register(DeleteAction.self)
        register(LogAction.self)
        register(StoreAction.self)
        register(SendAction.self)
        register(NotifyAction.self)
    }
    
    public func register<A: Action>(_ action: A.Type) {
        for verb in A.verbs {
            actions[verb.lowercased()] = action
        }
    }
    
    public func action(for verb: String) -> (any Action)? {
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
public struct SendEmailAction: Action {
    public static let semanticRole: ActionRole = .response
    public static let verbs: Set<String> = ["sendemail", "email"]
    public static let prepositions: Set<Preposition> = [.to, .via]
    
    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> Any {
        guard let emailService = context.service(EmailService.self) else {
            throw ActionError.missingService("EmailService")
        }
        
        guard let recipient: String = context.resolve(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }
        
        let email = Email(
            to: recipient,
            subject: result.specifiers[safe: 0] ?? "No Subject",
            body: result.specifiers[safe: 1] ?? ""
        )
        
        return try await emailService.send(email)
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
        let user = try await ActionRegistry.shared
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
        context.bind("user", to: user)
        
        // <Retrieve> the <user: record> from the <user-repository>
        let userRecord = try await ActionRegistry.shared
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
        context.bind("userRecord", to: userRecord)
        
        // <Compute> the <password: hash> for the <credentials>
        let password = try await ActionRegistry.shared
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
        context.bind("password", to: password)
        
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
