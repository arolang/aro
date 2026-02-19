# ARO-0004: Actions

* Proposal: ARO-0004
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0003

## Abstract

This proposal defines the action system in ARO, where actions are the verbs that give meaning to ARO statements. Actions transform data, interact with services, and produce results. Each action has a semantic role that determines its data flow direction and valid prepositions.

## Motivation

ARO describes *what* should happen; actions define *how* it executes:

1. **Semantic Classification**: Actions are categorized by their data flow direction
2. **Execution Binding**: Verbs map to concrete implementations
3. **Extensibility**: Custom actions can be added for domain-specific behavior
4. **Type Safety**: Actions validate inputs and produce typed outputs

## Proposed Solution

### 1. Action Architecture

```
+---------------------------------------------+
|           ARO Statement                     |
|  Extract the <user> from the <request>.   |
+----------------------+----------------------+
                       |
                       v
+---------------------------------------------+
|           Action Registry                   |
|    "extract" --> ExtractAction.self         |
+----------------------+----------------------+
                       |
                       v
+---------------------------------------------+
|         ActionImplementation                |
|  struct ExtractAction: ActionImplementation |
|    - role: .request                         |
|    - verbs: ["extract", "parse", "get"]     |
|    - validPrepositions: [.from, .via]       |
+----------------------+----------------------+
                       |
                       v
+---------------------------------------------+
|         Execution Context                   |
|  - resolve variables                        |
|  - bind results                             |
|  - access services                          |
|  - emit events                              |
+---------------------------------------------+
```

---

### 2. Action Roles

Actions are classified by their data flow direction:

```
+-------------+     +-------------+     +-------------+
|  External   | --> |  Internal   | --> |  External   |
|  Sources    |     |   State     |     |  Targets    |
+-------------+     +-------------+     +-------------+
       |                   |                   |
       v                   v                   v
   REQUEST              OWN              RESPONSE
   Extract            Compute             Return
   Retrieve           Validate            Throw
   Fetch              Transform           Send
   Read               Create              Log
                      Update              Write
                      Filter
                      Sort                EXPORT
                      Merge               Publish
                      Delete              Store
                                          Emit

                    SERVER
                    Start
                    Stop
                    Listen
                    Keepalive
```

#### 2.1 REQUEST Actions (External to Internal)

REQUEST actions bring data from external sources into the internal execution context.

| Action | Verbs | Prepositions | Description |
|--------|-------|--------------|-------------|
| **Extract** | extract, parse, get | from, via | Extract values from objects/structures |
| **ParseHtml** | parsehtml | from | Parse HTML/XML and extract structured data (see ARO-0011) |
| **Retrieve** | retrieve, fetch, load, find | from | Retrieve data from repositories |
| **Receive** | receive | from, via | Receive data from external sources |
| **Request** | request, http | from, to, via, with | Make HTTP requests |
| **Read** | read | from | Read data from files |
| **List** | list | from | List directory contents |
| **Stat** | stat | for | Get file/directory metadata |
| **Exists** | exists | for | Check if file/directory exists |

#### 2.2 OWN Actions (Internal to Internal)

OWN actions transform, validate, and manipulate data within the internal execution context.

| Action | Verbs | Prepositions | Description |
|--------|-------|--------------|-------------|
| **Compute** | compute, calculate, derive | from, for, with | Compute values using operations |
| **Validate** | validate, verify, check | for, against, with | Validate data against rules |
| **Compare** | compare, match | against, with, to | Compare two values |
| **Transform** | transform, convert, map | from, into, to | Transform data types |
| **Create** | create, build, construct | with, from, for, to | Create new entities |
| **Update** | update, modify, change, set | with, to, for, from | Update existing entities |
| **Filter** | filter | from | Filter collections |
| **Sort** | sort, order, arrange | for, with | Sort collections |
| **Split** | split | from | Split strings by delimiter |
| **Merge** | merge, combine, join, concat | with, into, from | Merge collections or objects |
| **Delete** | delete, remove, destroy, clear | from, for | Delete entities |
| **Map** | map | from, to | Map collections to different types |
| **Reduce** | reduce, aggregate | from, with | Reduce collections to single values |
| **Accept** | accept | on | Accept state transitions |
| **Given** | given | with | Set up test data |
| **When** | when | from | Execute feature set in tests |
| **Then** | then | with | Assert test conditions |
| **Assert** | assert | for, with | Direct test assertions |

#### 2.3 RESPONSE Actions (Internal to External)

RESPONSE actions send data from the internal context to external destinations.

| Action | Verbs | Prepositions | Description |
|--------|-------|--------------|-------------|
| **Return** | return, respond | for, to, with | Return response from feature set |
| **Throw** | throw, raise, fail | for | Throw an error |
| **Send** | send, dispatch | to, via, with | Send data externally |
| **Log** | log, print, output, debug | for, to, with | Log messages to stdout or stderr |
| **Write** | write | to, into | Write data to files |
| **Append** | append | to, into | Append data to files |
| **Notify** | notify, alert, signal | to, for, with | Send notifications |
| **Broadcast** | broadcast | to, via | Broadcast to all connections |

##### Log Action Output Streams

The Log action supports directing output to stdout (default) or stderr using qualifiers:

```aro
(* Default: stdout *)
Log "Application started" to the <console>.

(* Explicit stdout *)
Log "Processing..." to the <console: output>.

(* Error stream *)
Log "Warning: configuration missing" to the <console: error>.
```

**Stream Selection:**
- No qualifier or `output` → stdout
- `error` qualifier → stderr
- Unknown qualifiers → stdout (graceful fallback)

This enables proper separation of diagnostic/error messages from normal output in production environments. For example, in data pipeline applications where stdout contains actual data and stderr contains progress indicators and error messages:

```aro
(* Data to stdout *)
Log <json-record> to the <console>.

(* Progress to stderr *)
Log "Processed 1000 records" to the <console: error>.
```

#### 2.4 EXPORT Actions (Internal to Persistent)

EXPORT actions make data available beyond the current execution scope.

| Action | Verbs | Prepositions | Description |
|--------|-------|--------------|-------------|
| **Publish** | publish, export, expose, share | with | Publish variables globally |
| **Store** | store, save, persist | into, to, in | Store data to repositories |
| **Emit** | emit | with, to | Emit domain events |

#### 2.5 SERVER Actions (Service Management)

SERVER actions manage long-running services and application lifecycle.

| Action | Verbs | Prepositions | Description |
|--------|-------|--------------|-------------|
| **Start** | start | with | Start services (HTTP, socket, file-monitor) |
| **Stop** | stop | with | Stop services |
| **Listen** | listen, await | on, for, to | Listen on ports or for events |
| **Connect** | connect | to, with | Connect to remote servers |
| **Close** | close, disconnect, terminate | with, from | Close connections |
| **Keepalive** | wait, keepalive, block | for | Keep application alive for events |
| **Make** | make, touch, mkdir, createdirectory | to, for, at | Create files/directories |
| **Copy** | copy | to | Copy files/directories |
| **Move** | move, rename | to | Move/rename files |
| **Execute** | execute, exec, run, shell | with | Execute system commands |
| **Call** | call, invoke | with, to | Call external services |

---

### 3. ActionImplementation Protocol

All actions implement this protocol:

```swift
public protocol ActionImplementation: Sendable {
    /// The semantic role of this action
    static var role: ActionRole { get }

    /// Verbs that trigger this action (lowercase)
    static var verbs: Set<String> { get }

    /// Valid prepositions for this action
    static var validPrepositions: Set<Preposition> { get }

    /// Required initializer (actions should be stateless)
    init()

    /// Execute the action asynchronously
    func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable
}
```

#### 3.1 ActionRole Enum

```swift
public enum ActionRole: String, Sendable, CaseIterable {
    case request    // External -> Internal
    case own        // Internal -> Internal
    case response   // Internal -> External
    case export     // Publish/Store mechanism
}
```

---

### 4. Descriptors

Actions receive structured information about the statement through descriptors.

#### 4.1 ResultDescriptor

Describes the result part of an ARO statement (the output variable to be created).

```swift
public struct ResultDescriptor: Sendable {
    /// The base name (variable name to bind)
    public let base: String

    /// Type specifiers from the qualified noun
    public let specifiers: [String]

    /// Source location for error reporting
    public let span: SourceSpan

    /// Full qualified name for display
    public var fullName: String {
        specifiers.isEmpty ? base : "\(base): \(specifiers.joined(separator: "."))"
    }
}
```

Example: In `Extract the <user: identifier> from ...`, the ResultDescriptor has:
- `base` = "user"
- `specifiers` = ["identifier"]

#### 4.2 ObjectDescriptor

Describes the object part of an ARO statement (the input source).

```swift
public struct ObjectDescriptor: Sendable {
    /// The preposition connecting action to object
    public let preposition: Preposition

    /// The base name (source variable/resource)
    public let base: String

    /// Type specifiers from the qualified noun
    public let specifiers: [String]

    /// Source location for error reporting
    public let span: SourceSpan

    /// Whether this references an external source
    public var isExternalReference: Bool

    /// Full qualified name for display
    public var fullName: String

    /// Key path for nested access (e.g., "request.parameters.userId")
    public var keyPath: String
}
```

Example: In `Extract ... from the <request: parameters>`, the ObjectDescriptor has:
- `preposition` = .from
- `base` = "request"
- `specifiers` = ["parameters"]
- `keyPath` = "request.parameters"

---

### 5. Execution Context

Actions access runtime services through the execution context:

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

    // Response management
    func setResponse(_ response: Response)
    func getResponse() -> Response?

    // Event emission
    func emit(_ event: any RuntimeEvent)

    // Metadata
    var featureSetName: String { get }
    var businessActivity: String { get }
    var executionId: String { get }
    var parent: ExecutionContext? { get }

    // Wait state management (for long-running applications)
    func enterWaitState()
    func waitForShutdown() async throws
    var isWaiting: Bool { get }
    func signalShutdown()
}
```

---

### 6. Creating Custom Actions

#### 6.1 Step-by-Step Guide

1. **Define the action struct** conforming to `ActionImplementation`
2. **Specify the role** based on data flow direction
3. **List all verbs** that should trigger this action
4. **Declare valid prepositions** for the object clause
5. **Implement execute()** to perform the action logic
6. **Register with ActionRegistry** at application startup

#### 6.2 Example: SMS Action

```swift
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
        // 1. Validate preposition
        try validatePreposition(object.preposition)

        // 2. Get required service
        guard let smsService = context.service(SMSService.self) else {
            throw ActionError.missingService("SMSService")
        }

        // 3. Get input data
        let message: String = try context.require(result.base)
        let recipient: String
        if let resolved: String = context.resolve(object.base) {
            recipient = resolved
        } else {
            recipient = object.base
        }

        // 4. Perform the action
        let smsResult = try await smsService.send(
            message: message,
            to: recipient
        )

        // 5. Bind result and emit event
        context.bind(result.base, value: smsResult)
        context.emit(SMSSentEvent(
            recipient: recipient,
            messageId: smsResult.id
        ))

        return smsResult
    }
}
```

Usage in ARO:

```aro
(Send Alert: Notification Handler) {
    Create the <message> with "Your order has shipped!".
    Extract the <phone> from the <user: phoneNumber>.
    SMS the <message> to the <phone>.
    Return an <OK: status> for the <notification>.
}
```

#### 6.3 Example: Database Query Action

```swift
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

        guard let db = context.service(DatabaseService.self) else {
            throw ActionError.missingService("DatabaseService")
        }

        // Get SQL - resolve as variable or use as literal
        let sql: String
        if let resolved: String = context.resolve(object.base) {
            sql = resolved
        } else {
            sql = object.base
        }

        let rows = try await db.query(sql)

        context.bind(result.base, value: rows)
        context.emit(QueryExecutedEvent(
            sql: sql,
            rowCount: rows.count,
            executionId: context.executionId
        ))

        return rows
    }
}
```

---

### 7. ActionRegistry

The ActionRegistry maintains a mapping from verb strings to their implementations.

```swift
public actor ActionRegistry {
    /// Shared singleton instance
    public static let shared = ActionRegistry()

    /// Register a custom action
    public func register<A: ActionImplementation>(_ action: A.Type) {
        for verb in A.verbs {
            actions[verb.lowercased()] = action
        }
    }

    /// Get an action implementation for a verb
    public func action(for verb: String) -> (any ActionImplementation)? {
        guard let actionType = actions[verb.lowercased()] else {
            return nil
        }
        return actionType.init()
    }

    /// Execute an action for a given verb
    public func execute(
        verb: String,
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        guard let action = action(for: verb) else {
            throw ActionError.unknownAction(verb)
        }
        return try await action.execute(
            result: result,
            object: object,
            context: context
        )
    }

    /// Check if a verb is registered
    public func isRegistered(_ verb: String) -> Bool

    /// Get all registered verbs
    public var registeredVerbs: Set<String>

    /// Get all registered actions grouped by role
    public var actionsByRole: [ActionRole: [String]]
}
```

#### 7.1 Registering Custom Actions

```swift
// At application startup
ActionRegistry.shared.register(SendSMSAction.self)
ActionRegistry.shared.register(QueryAction.self)
```

---

### 8. Action Lifecycle

```
+--------------------------------------------------------------+
|                    Action Execution                          |
+--------------------------------------------------------------+
|  1. Parse ARO Statement                                      |
|     +-- Extract: Action, Result, Object                      |
|                                                              |
|  2. Resolve Action                                           |
|     +-- ActionRegistry.action(for: verb)                     |
|                                                              |
|  3. Validate Preposition                                     |
|     +-- Check: object.preposition in Action.validPrepositions|
|                                                              |
|  4. Resolve Dependencies                                     |
|     +-- Context.resolve(object.base)                         |
|                                                              |
|  5. Execute Action                                           |
|     +-- action.execute(result, object, context)              |
|                                                              |
|  6. Bind Result                                              |
|     +-- Context.bind(result.base, value)                     |
|                                                              |
|  7. Continue or Return                                       |
|     +-- Next statement or response                           |
+--------------------------------------------------------------+
```

---

### 9. Error Handling

Actions should throw `ActionError` for recoverable errors:

```swift
public enum ActionError: Error, Sendable {
    case undefinedVariable(String)
    case propertyNotFound(property: String, on: String)
    case invalidPreposition(action: String, received: Preposition, expected: Set<Preposition>)
    case missingService(String)
    case undefinedRepository(String)
    case typeMismatch(expected: String, actual: String)
    case thrown(type: String, reason: String, context: String)
    case unknownAction(String)
    case validationFailed(String)
    case comparisonFailed(String)
    case ioError(String)
    case networkError(String)
    case timeout(String)
    case featureSetNotFound(String)
    case runtimeError(String)
}
```

---

### 10. Best Practices

#### 10.1 Single Responsibility
Each action should do one thing well. If an action is doing too much, split it into multiple actions.

#### 10.2 Fail Fast
Validate inputs early and throw descriptive errors:

```swift
try validatePreposition(object.preposition)

guard let service = context.service(MyService.self) else {
    throw ActionError.missingService("MyService")
}

guard let input: String = context.resolve(object.base) else {
    throw ActionError.undefinedVariable(object.base)
}
```

#### 10.3 Event Emission
Emit events for significant operations to enable reactive features:

```swift
context.emit(DataProcessedEvent(
    source: object.base,
    result: result.base,
    executionId: context.executionId
))
```

#### 10.4 Service Dependencies
Access services through the context, not stored references:

```swift
// Good: Get service from context each time
guard let db = context.service(DatabaseService.self) else { ... }

// Bad: Store service in action (breaks Sendable)
// private var db: DatabaseService  // Don't do this
```

#### 10.5 Thread Safety
Actions must be `Sendable` and thread-safe. Do not store mutable state in actions.

---

### 11. Complete Built-in Actions Reference

| # | Action | Role | Verbs | Prepositions |
|---|--------|------|-------|--------------|
| 1 | Extract | request | extract, parse, get | from, via |
| 2 | Retrieve | request | retrieve, fetch, load, find | from |
| 3 | Receive | request | receive | from, via |
| 4 | Request | request | request, http | from, to, via, with |
| 5 | Read | request | read | from |
| 6 | List | request | list | from |
| 7 | Stat | request | stat | for |
| 8 | Exists | request | exists | for |
| 9 | Compute | own | compute, calculate, derive | from, for, with |
| 10 | Validate | own | validate, verify, check | for, against, with |
| 11 | Compare | own | compare, match | against, with, to |
| 12 | Transform | own | transform, convert, map | from, into, to |
| 13 | Create | own | create, build, construct | with, from, for, to |
| 14 | Update | own | update, modify, change, set | with, to, for, from |
| 15 | Filter | own | filter | from |
| 16 | Sort | own | sort, order, arrange | for, with |
| 17 | Split | own | split | from |
| 18 | Merge | own | merge, combine, join, concat | with, into, from |
| 19 | Delete | own | delete, remove, destroy, clear | from, for |
| 20 | Map | own | map | from, to |
| 21 | Reduce | own | reduce, aggregate | from, with |
| 22 | Accept | own | accept | on |
| 23 | Given | own | given | with |
| 24 | When | own | when | from |
| 25 | Then | own | then | with |
| 26 | Assert | own | assert | for, with |
| 27 | Start | server | start | with |
| 28 | Stop | server | stop | with |
| 29 | Listen | server | listen, await | on, for, to |
| 30 | Connect | server | connect | to, with |
| 31 | Close | server | close, disconnect, terminate | with, from |
| 32 | Keepalive | server | wait, keepalive, block | for |
| 33 | Make | server | make, touch, mkdir, createdirectory | to, for, at |
| 34 | Copy | server | copy | to |
| 35 | Move | server | move, rename | to |
| 36 | Return | response | return, respond | for, to, with |
| 37 | Throw | response | throw, raise, fail | for |
| 38 | Send | response | send, dispatch | to, via, with |
| 39 | Log | response | log, print, output, debug | for, to, with |
| 40 | Write | response | write | to, into |
| 41 | Append | response | append | to, into |
| 42 | Notify | response | notify, alert, signal | to, for, with |
| 43 | Broadcast | response | broadcast | to, via |
| 44 | Publish | export | publish, export, expose, share | with |
| 45 | Store | export | store, save, persist | into, to, in |
| 46 | Emit | export | emit | with, to |
| 47 | Execute | own | execute, exec, run, shell | with |
| 48 | Call | own | call, invoke | from, to, with, via |

---

## Grammar

Actions are used within ARO statements:

```ebnf
aro_statement = action_clause , result_clause , object_clause , [ with_clause ] ;

action_clause = "<" , verb , ">" ;
result_clause = article , qualified_noun ;
object_clause = preposition , article , qualified_noun ;
with_clause = "with" , ( literal | expression | map_literal ) ;

verb = identifier ;
preposition = "from" | "for" | "into" | "to" | "via"
            | "with" | "against" | "on" | "in" | "at" ;
```

---

## Examples

### Basic Actions

```aro
(* REQUEST: Extract data from structures *)
Extract the <user-id> from the <request: parameters>.

(* OWN: Compute derived values *)
Compute the <hash: hash> from the <password>.

(* RESPONSE: Return results *)
Return an <OK: status> with <user>.

(* EXPORT: Store to repository *)
Store the <user> into the <user-repository>.
```

### Service Management

```aro
(Application-Start: My Server) {
    Log "Starting server..." to the <console>.
    Start the <http-server> with <contract>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}
```

### Custom Domain Actions

```aro
(Send Welcome: UserCreated Handler) {
    Extract the <user> from the <event: user>.
    Extract the <phone> from the <user: phoneNumber>.
    SMS the <welcome-message> to the <phone>.
    Return an <OK: status> for the <notification>.
}
```

---

## Implementation Notes

- Actions are instantiated per-execution via `init()`
- The `execute` method must be thread-safe
- Services should be accessed through the context, not stored
- Custom actions integrate with the same event system as built-in actions
- Use `validatePreposition()` helper to check prepositions early
- Verbs are case-insensitive (stored lowercase in registry)
- All core action types conform to `Sendable` for Swift concurrency safety

---

## Implementation Location

The Action system is implemented in:

- `Sources/ARORuntime/Actions/ActionProtocol.swift` - `ActionImplementation` protocol and `ActionRole` enum
- `Sources/ARORuntime/Actions/ActionDescriptors.swift` - `ResultDescriptor` and `ObjectDescriptor`
- `Sources/ARORuntime/Actions/ActionError.swift` - `ActionError` enum
- `Sources/ARORuntime/Actions/ActionRegistry.swift` - `ActionRegistry` for registration
- `Sources/ARORuntime/Actions/BuiltIn/` - All 48 built-in action implementations
- `Sources/ARORuntime/Core/ExecutionContext.swift` - `ExecutionContext` protocol
