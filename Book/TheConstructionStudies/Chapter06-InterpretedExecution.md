# Chapter 6: Interpreted Execution

## Execution Engine Architecture

The runtime engine orchestrates program execution. It manages the event bus, registers feature sets, and dispatches events to handlers.

```swift
// ExecutionEngine.swift
public actor ExecutionEngine {
    private let eventBus: EventBus
    private let actionRegistry: ActionRegistry
    private var featureSetExecutors: [String: FeatureSetExecutor]
}
```

<svg viewBox="0 0 700 400" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .engine { fill: #e8f4e8; }
    .bus { fill: #f4e8e8; }
    .executor { fill: #e8e8f4; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow13); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 12px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow13" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- ExecutionEngine -->
  <rect x="230" y="30" width="240" height="80" rx="5" class="box engine"/>
  <text x="350" y="55" class="title" text-anchor="middle">ExecutionEngine</text>
  <text x="240" y="75" class="label">• Loads program</text>
  <text x="240" y="90" class="label">• Registers handlers with EventBus</text>
  <text x="240" y="105" class="label">• Executes Application-Start</text>

  <!-- EventBus -->
  <rect x="230" y="140" width="240" height="70" rx="5" class="box bus"/>
  <text x="350" y="165" class="title" text-anchor="middle">EventBus</text>
  <text x="240" y="185" class="label">• Routes events to handlers</text>
  <text x="240" y="200" class="label">• Async dispatch with AsyncStream</text>

  <!-- FeatureSetExecutors -->
  <rect x="30" y="250" width="180" height="100" rx="5" class="box executor"/>
  <text x="120" y="275" class="title" text-anchor="middle">FeatureSetExecutor</text>
  <text x="120" y="295" class="label" text-anchor="middle">"Application-Start"</text>
  <text x="40" y="315" class="label">Executes statements</text>
  <text x="40" y="330" class="label">Manages context</text>

  <rect x="260" y="250" width="180" height="100" rx="5" class="box executor"/>
  <text x="350" y="275" class="title" text-anchor="middle">FeatureSetExecutor</text>
  <text x="350" y="295" class="label" text-anchor="middle">"UserCreated Handler"</text>

  <rect x="490" y="250" width="180" height="100" rx="5" class="box executor"/>
  <text x="580" y="275" class="title" text-anchor="middle">FeatureSetExecutor</text>
  <text x="580" y="295" class="label" text-anchor="middle">"getUser API"</text>

  <!-- ActionRegistry -->
  <rect x="530" y="30" width="140" height="80" rx="5" class="box"/>
  <text x="600" y="55" class="title" text-anchor="middle">ActionRegistry</text>
  <text x="540" y="75" class="label">verb → Action</text>
  <text x="540" y="90" class="label">48 built-in</text>

  <!-- Arrows -->
  <path d="M 350 110 L 350 140" class="arrow"/>
  <path d="M 280 210 L 120 250" class="arrow"/>
  <path d="M 350 210 L 350 250" class="arrow"/>
  <path d="M 420 210 L 580 250" class="arrow"/>
  <path d="M 470 70 L 530 70" class="arrow"/>
</svg>

**Figure 6.1**: Execution engine architecture. The engine coordinates between EventBus and FeatureSetExecutors.

---

## ExecutionContext Protocol

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
}
```

The context is the action's view of the world—it can read variables, bind new ones, access services, and emit events.

---

## FeatureSetExecutor

Each feature set gets an executor that processes statements sequentially:

```swift
public final class FeatureSetExecutor {
    private let featureSet: FeatureSet
    private let actionRegistry: ActionRegistry
    private var context: RuntimeContext

    public func execute() async throws {
        for statement in featureSet.statements {
            try await executeStatement(statement)

            // Check for response short-circuit
            if context.getResponse() != nil {
                break
            }
        }
    }
}
```

<svg viewBox="0 0 600 300" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .stmt { fill: #e8f4e8; }
    .response { fill: #f4e8e8; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow14); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow14" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- Statements -->
  <rect x="50" y="30" width="200" height="40" rx="5" class="box stmt"/>
  <text x="150" y="55" class="label" text-anchor="middle">&lt;Extract&gt; the &lt;id&gt; from &lt;request&gt;.</text>

  <rect x="50" y="90" width="200" height="40" rx="5" class="box stmt"/>
  <text x="150" y="115" class="label" text-anchor="middle">&lt;Retrieve&gt; the &lt;user&gt; from &lt;repo&gt;.</text>

  <rect x="50" y="150" width="200" height="40" rx="5" class="box response"/>
  <text x="150" y="175" class="label" text-anchor="middle">&lt;Return&gt; an &lt;OK&gt; with &lt;user&gt;.</text>

  <rect x="50" y="210" width="200" height="40" rx="5" class="box" fill="#ddd"/>
  <text x="150" y="235" class="label" text-anchor="middle">(not executed - response set)</text>

  <!-- Arrows -->
  <path d="M 150 70 L 150 90" class="arrow"/>
  <path d="M 150 130 L 150 150" class="arrow"/>
  <path d="M 250 170 L 350 170" class="arrow"/>

  <!-- Response check -->
  <rect x="360" y="140" width="180" height="60" rx="5" class="box"/>
  <text x="450" y="165" class="title" text-anchor="middle">Response Short-Circuit</text>
  <text x="370" y="185" class="label">Return/Throw sets response</text>
  <text x="370" y="195" class="label">→ execution stops</text>
</svg>

**Figure 6.2**: Statement execution sequence. Return or Throw sets a response, causing remaining statements to be skipped.

---

## ActionRegistry Design

Actions are registered by their verbs and looked up at execution time:

```swift
public actor ActionRegistry {
    private var actions: [String: any ActionImplementation.Type] = [:]

    public func register<A: ActionImplementation>(_ action: A.Type) {
        for verb in A.verbs {
            actions[verb.lowercased()] = action
        }
    }

    public func action(for verb: String) -> (any ActionImplementation)? {
        guard let actionType = actions[verb.lowercased()] else { return nil }
        return actionType.init()  // Stateless instantiation
    }
}
```

ARO has 48 built-in actions. Each is registered at startup:

```swift
// ActionRegistry initialization
ActionRegistry.shared.register(ExtractAction.self)
ActionRegistry.shared.register(RetrieveAction.self)
ActionRegistry.shared.register(ComputeAction.self)
ActionRegistry.shared.register(ReturnAction.self)
// ... 44 more
```

<svg viewBox="0 0 600 250" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow15); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow15" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- Statement -->
  <rect x="30" y="30" width="220" height="40" rx="5" class="box"/>
  <text x="140" y="55" class="label" text-anchor="middle">&lt;Extract&gt; the &lt;user&gt; from &lt;request&gt;.</text>

  <!-- Verb lookup -->
  <rect x="30" y="100" width="100" height="30" rx="5" class="box"/>
  <text x="80" y="120" class="label" text-anchor="middle">verb: "extract"</text>

  <!-- Registry -->
  <rect x="170" y="90" width="180" height="110" rx="5" class="box"/>
  <text x="260" y="110" class="title" text-anchor="middle">ActionRegistry</text>
  <text x="180" y="135" class="label">"extract" → ExtractAction</text>
  <text x="180" y="150" class="label">"compute" → ComputeAction</text>
  <text x="180" y="165" class="label">"return" → ReturnAction</text>
  <text x="180" y="180" class="label">... (48 total)</text>

  <!-- Action instance -->
  <rect x="400" y="90" width="160" height="70" rx="5" class="box"/>
  <text x="480" y="110" class="title" text-anchor="middle">ExtractAction</text>
  <text x="410" y="130" class="label">role: .request</text>
  <text x="410" y="145" class="label">prepositions: [.from, .via]</text>

  <!-- Arrows -->
  <path d="M 140 70 L 80 100" class="arrow"/>
  <path d="M 130 115 L 170 115" class="arrow"/>
  <path d="M 350 125 L 400 125" class="arrow"/>
  <text x="365" y="118" class="label">init()</text>
</svg>

**Figure 6.3**: Action dispatch sequence. The verb is looked up in the registry, and a fresh action instance is created.

---

## Descriptor-Based Invocation

Actions receive structured information via descriptors:

```swift
public struct ResultDescriptor: Sendable {
    public let base: String         // Variable to bind
    public let specifiers: [String] // Qualifiers
    public let span: SourceSpan
}

public struct ObjectDescriptor: Sendable {
    public let preposition: Preposition
    public let base: String
    public let specifiers: [String]
    public let keyPath: String      // "request.parameters.userId"
}
```

The executor builds these from the AST:

```swift
let resultDesc = ResultDescriptor(
    base: statement.result.base,
    specifiers: statement.result.specifiers,
    span: statement.result.span
)

let objectDesc = ObjectDescriptor(
    preposition: statement.object.preposition,
    base: statement.object.noun.base,
    specifiers: statement.object.noun.specifiers,
    ...
)
```

---

## Context Hierarchy

For loops, child contexts are created:

```swift
for each <item> in <items> {
    // child context created per iteration
    // item is bound fresh each time
}
```

<svg viewBox="0 0 500 200" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .child { fill: #e8f4e8; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow16); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow16" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- Parent context -->
  <rect x="150" y="20" width="200" height="60" rx="5" class="box"/>
  <text x="250" y="40" class="title" text-anchor="middle">Parent Context</text>
  <text x="160" y="60" class="label">items: [a, b, c]</text>
  <text x="160" y="75" class="label">user: {...}</text>

  <!-- Child contexts -->
  <rect x="30" y="120" width="130" height="60" rx="5" class="box child"/>
  <text x="95" y="140" class="title" text-anchor="middle">Iteration 1</text>
  <text x="40" y="160" class="label">item: a</text>

  <rect x="185" y="120" width="130" height="60" rx="5" class="box child"/>
  <text x="250" y="140" class="title" text-anchor="middle">Iteration 2</text>
  <text x="195" y="160" class="label">item: b</text>

  <rect x="340" y="120" width="130" height="60" rx="5" class="box child"/>
  <text x="405" y="140" class="title" text-anchor="middle">Iteration 3</text>
  <text x="350" y="160" class="label">item: c</text>

  <!-- Arrows -->
  <path d="M 200 80 L 95 120" class="arrow"/>
  <path d="M 250 80 L 250 120" class="arrow"/>
  <path d="M 300 80 L 405 120" class="arrow"/>
  <text x="170" y="105" class="label">parent</text>
</svg>

**Figure 6.4**: Context tree. Child contexts inherit from parent but have their own bindings for loop variables.

---

## Chapter Summary

The interpreted execution model is straightforward:

1. **ExecutionEngine** loads the program and registers feature sets with EventBus
2. **EventBus** routes events to matching handlers
3. **FeatureSetExecutor** processes statements sequentially
4. **ActionRegistry** maps verbs to action implementations
5. **Descriptors** carry structured information to actions
6. **Context hierarchy** enables scoped variable binding for loops

The interpreter is the reference implementation. Native compilation (Chapter 8) generates code that calls the same action implementations through a C bridge.

Implementation references:
- `Sources/ARORuntime/Core/ExecutionEngine.swift`
- `Sources/ARORuntime/Core/FeatureSetExecutor.swift`
- `Sources/ARORuntime/Actions/ActionRegistry.swift`

---

*Next: Chapter 7 — Event Architecture*
