# ARO: The Essential Primer

**A Technical Introduction to Action-Result-Object**

---

*Language version: pre-alpha · Revision: 0.1 · March 2026*

---

## Abstract

ARO (Action-Result-Object) is a domain-specific language designed to express business features as structured English sentences. It targets backend developers who build event-driven services and REST APIs. The language deliberately constrains its syntax to a single grammatical pattern, trading expressiveness for consistency, auditability, and alignment between business requirements and running code. This primer introduces the language, its internal architecture, its compilation pipeline, and the domains in which its constraints become advantages.

---

## 1. The Problem ARO Solves

Every software project maintains two parallel artefacts: the specification and the code. In theory, they describe the same thing. In practice, they diverge within weeks of the first release. The specification becomes an archaeological document, accurate only at the moment it was written. The code becomes the real specification, understood only by the developers who wrote it.

This divergence is not a process failure. It is a structural failure. Specifications and code live in different languages, maintained by different tools, updated by different people on different schedules. Synchronising them requires discipline that rarely survives contact with deadlines.

ARO eliminates the gap by making the specification and the code the same artefact. A feature written in ARO reads like a business description. It also compiles and runs. There is nothing to keep in sync because there is only one thing.

This idea has precedent. SQL describes data retrieval in business terms and executes those descriptions directly. Terraform declares desired infrastructure state and applies it. Make declares build dependencies and resolves them. Each language succeeded because it made domain intent directly executable. ARO applies that pattern to the broader domain of business logic.

---

## 2. Origins: Feature-Driven Development

In 1997, software consultant Jeff De Luca faced a failing project at United Overseas Bank in Singapore. Dozens of developers from multiple countries could not agree on requirements. Business analysts and engineers spoke different languages, literally and figuratively.

De Luca and Peter Coad devised Feature-Driven Development (FDD), a methodology built around a single deceptively simple observation: every software feature can be expressed as a sentence following the pattern *Action the Result for the Object*. "Calculate the total for the order." "Validate the credentials for the user." "Send the notification to the customer."

This sentence structure worked because it was natural to both audiences. A business analyst understood it as a requirement. A developer understood it as a specification. Both could verify that the implementation matched the intent.

FDD worked on that project and influenced a generation of methodology thinkers before Scrum absorbed the industry's attention. The core insight — that business language can be formally structured enough to be executable — waited twenty-five years for the right enabling conditions.

Those conditions arrived in the form of large language models, capable toolchains, and the growing recognition that the bottleneck in software development is communication, not computation. ARO is the realisation of FDD's vision: the structured sentence is not just documentation, it is the program.

---

## 3. The Language

### 3.1 The Statement

Every ARO statement follows one grammatical pattern without exception:

```
Action [article] <Result> preposition [article] <Object>.
```

The *Action* is a verb drawn from a vocabulary of approximately fifty built-in words. The *Result* is a named binding that will hold the produced value, written in angle brackets. The *Object*, introduced by a preposition, is the input to the action. Articles (`the`, `a`, `an`) are optional syntactic sugar that improve readability without affecting semantics.

A representative statement:

```aro
Extract the <user-id> from the <pathParameters: id>.
```

This statement pulls the URL path parameter named `id` and binds it to the local variable `user-id`. The verb `Extract` signals that data is flowing inward from an external source. The preposition `from` indicates the direction of that flow. The colon notation inside the angle brackets (`pathParameters: id`) is a *qualifier*, selecting a specific field within the object.

Every ARO statement is this legible. There are no operator precedences to memorise, no special forms for loops or exceptions, no syntactic irregularities. If you can read one statement, you can read any statement in any ARO program.

### 3.2 Feature Sets

Statements are grouped into *feature sets*, which are named collections of statements that execute together when triggered by an event.

```aro
(createUser: User API) {
    Extract the <data> from the <request: body>.
    Validate the <data> against the <user: schema>.
    Create the <user> with <data>.
    Emit a <UserCreated: event> with <user>.
    Return a <Created: status> with <user>.
}
```

The header `(createUser: User API)` gives the feature set two identifiers. The first, `createUser`, matches an `operationId` in an OpenAPI specification. The second, `User API`, is the *business activity* — the domain context under which this feature set operates. When an HTTP POST arrives at the route corresponding to `createUser`, the event bus dispatches execution to this feature set.

The feature set above reads as a complete business description: extract the request body, validate it against the schema, create a user record, notify the rest of the system that a user was created, and return a 201 response. A developer who has never seen ARO can read this and understand what the code does. A business analyst with no programming background can verify that it matches the requirement.

### 3.3 The Qualifier Syntax

Qualifiers refine a variable reference to access a specific aspect of its value. They follow a colon inside the angle brackets:

```aro
Extract the <email> from the <user: email>.
Extract the <id> from the <pathParameters: id>.
Compute the <length: length> from the <message>.
```

The qualifier can select a field (`:email`, `:id`), specify a transformation (`:length`, `:uppercase`), or address a named source (`:body`, `:headers`). This uniform notation applies consistently across all variable references, eliminating the need for different accessor syntax for different data types.

### 3.4 Immutability and Data Flow

Variable bindings in ARO are immutable. Once a result is bound, it cannot be rebound to a different value within the same feature set. This design eliminates an entire category of bugs — the accidental overwrite — and makes data flow through a feature set completely traceable.

When a transformation produces a value that will be used differently downstream, a new name is introduced:

```aro
Compute the <first-length: length> from the <first-message>.
Compute the <second-length: length> from the <second-message>.
Compare the <first-length> against the <second-length>.
```

The qualifier-as-name pattern — where the result name carries the variable identity and the qualifier specifies the operation — allows multiple applications of the same transformation without name collisions.

### 3.5 The Happy Path

ARO source code contains only the success path. There is no error handling syntax because there is no error handling responsibility. When an action fails — the database returns no record, the schema validation rejects the input, the HTTP request times out — the runtime generates a structured error response describing exactly what failed and why, in business terms.

A failed `Retrieve` produces: *"Cannot retrieve the user from the user-repository where id = 530."* That message is the error. The developer need not write code to produce it.

This design is deliberately opinionated and deliberately incomplete. Complex conditional error handling — retry logic, fallback strategies, partial failures — must be implemented as custom actions. The language handles the common case; the extension mechanism handles everything else.

---

## 4. Internal Architecture

### 4.1 The Compilation Pipeline

ARO source code passes through a five-stage pipeline before execution:

```
.aro files
    │
    ▼
Lexer ────── Tokenises source, recognising articles, prepositions,
             compound identifiers, and qualified references.
    │
    ▼
Parser ───── Recursive descent. Produces a Program tree of FeatureSets,
             each containing a sequence of Statements (AROStatement or
             PublishStatement).
    │
    ▼
SemanticAnalyzer ── Builds per-feature-set SymbolTables. Validates
                    variable references, preposition legality, and
                    cross-feature-set published variable access.
    │
    ▼
Compiler ──── Orchestrates the three stages above. Produces validated
              AST ready for interpretation or code generation.
    │
    ├── Interpreter ── Executes directly via the Swift runtime
    │
    └── LLVMCodeGenerator ── Emits LLVM IR; compiled to native binary
```

All core types (`Token`, AST nodes, `SymbolTable`) are `Sendable` and immutable, satisfying Swift 6.2's strict concurrency model. The parser produces a data structure, not executable state. The semantic analyser operates on that data structure without modifying it. The result is a pipeline that can be parallelised at the file level without locking.

### 4.2 The Execution Engine

At runtime, the `ExecutionEngine` loads the compiled application, validates the existence of exactly one `Application-Start` feature set, starts configured services, and hands control to the event loop.

The `EventBus` is the central coordination mechanism. It maintains a registry of subscribed handlers — feature sets — indexed by event type. When an event is published, the bus finds all matching handlers and dispatches execution to each. Events are the only mechanism by which feature sets communicate. There are no direct calls between feature sets.

```
HTTP Request
    │
    ▼
RouteRegistry (consults openapi.yaml)
    │
    ▼
EventBus ── publishes HTTP route event
    │
    ▼
FeatureSetExecutor ── executes matching feature set
    │
    ▼
ActionRegistry ── dispatches each statement to its action implementation
    │
    ▼
Response
```

The `ActionRegistry` maps verbs to `ActionImplementation` instances. Every verb in the language is backed by a registered action. Custom actions extend the registry at startup; plugin actions are loaded from dynamic libraries and registered the same way.

### 4.3 Semantic Roles and Data Flow Classification

Each action carries a *semantic role* that classifies the direction of its data flow. The runtime uses these roles to determine how statements interact with the execution context.

| Role | Direction | Representative Verbs |
|------|-----------|----------------------|
| **REQUEST** | External → Internal | Extract, Retrieve, Fetch, Read |
| **OWN** | Internal → Internal | Compute, Validate, Create, Transform |
| **RESPONSE** | Internal → External (terminates) | Return, Throw |
| **EXPORT** | Internal → External (continues) | Store, Emit, Publish, Log |

This classification is not merely documentation. The `FeatureSetExecutor` uses it to determine whether a statement needs full execution or can be short-circuited in specific contexts. RESPONSE actions terminate the feature set; EXPORT actions continue it. The semantic role is the runtime's understanding of what a statement does, independently of its specific implementation.

### 4.4 The Repository System

Repositories are in-memory, event-sourced key-value stores managed by the runtime. They are not databases, though they can be backed by persistent storage via plugins.

```aro
Store the <user> into the <user-repository>.
Retrieve the <user> from the <user-repository> where id = <user-id>.
Update the <user> with <changes> in the <user-repository>.
```

Repositories emit change events automatically. Any feature set whose business activity contains the repository name followed by `Observer` receives those events:

```aro
(Sync Remote: user-repository Observer) {
    Extract the <user> from the <event: newValue>.
    Send the <sync-request> to the <remote-api> with <user>.
    Return an <OK: status> for the <sync>.
}
```

This pattern decouples the code that modifies data from the code that reacts to modifications. The `createUser` feature set stores a user. It has no knowledge of what happens next. The observer pattern handles all downstream consequences without any coupling between feature sets.

### 4.5 The Event Bus and Typed Events

The event bus supports both typed events (interpreter mode) and domain events (binary mode). Typed events carry structured payloads and enable compile-time validation of event shapes. Domain events are serialised payloads dispatched through a string-keyed registry — the mechanism used in compiled binaries where Swift types cannot cross the C ABI boundary.

Custom events follow the same subscription model as built-in events:

```aro
Emit a <UserCreated: event> with <user>.
```

Any feature set with the activity `UserCreated Handler` will receive this event. Handler guards allow filtering:

```aro
(Send Welcome Email: UserCreated Handler) when <role> is "customer" {
    ...
}
```

The guard is evaluated before the feature set body executes. If the condition is false, the handler is silently skipped. Multiple handlers for the same event type are all invoked; the order is not guaranteed.

---

## 5. Compilation to Native Binaries

ARO applications can be compiled to standalone native executables with `aro build`. The interpreter is the development workflow; native binaries are the deployment artefact.

The compilation path replaces the interpreter with an LLVM code generator. Each ARO statement becomes a call to the ARO C runtime (`AROCRuntime`), a precompiled static library that exposes the full action vocabulary through C ABI functions:

```c
// The runtime interface (simplified)
void aro_action_extract(AROContext* ctx, const char* result, const char* object);
void aro_action_retrieve(AROContext* ctx, const char* result, const char* object,
                         const char* field, const char* value);
void aro_action_return(AROContext* ctx, int status, const char* result);
```

The LLVM IR generator (`LLVMCodeGenerator.swift`) emits a `main` function that initialises the context, registers all feature sets as event handlers, and starts the event loop. Feature set bodies are emitted as LLVM functions that call into the C runtime sequentially.

The output is a self-contained binary that embeds the complete runtime, all actions, and all compiled plugin libraries. The only external dependency at runtime is the `openapi.yaml` specification file, which is read to configure HTTP routing.

This dual-mode architecture — interpreter for development, native binary for deployment — means that the same ARO source runs identically in both contexts. Parity is enforced by the test suite, which runs every example in both modes.

---

## 6. The Plugin System

When the built-in vocabulary of fifty actions is insufficient, plugins extend it. Plugins are packages installed into the application's `Plugins/` directory and loaded at startup.

ARO supports plugins written in Swift, Rust, C, C++, and Python. All native plugins communicate through a C ABI:

```c
char* aro_plugin_info(void);
char* aro_plugin_execute(const char* action, const char* input_json);
char* aro_plugin_qualifier(const char* qualifier, const char* input_json);
void  aro_plugin_free(char* ptr);
```

`aro_plugin_info` returns a JSON manifest declaring the plugin's name, version, and the actions and qualifiers it provides. `aro_plugin_execute` runs a named action, receiving and returning JSON. This protocol is deliberately simple: any language that can produce a shared library implementing these four functions can be an ARO plugin.

*Qualifiers* are a particular capability of plugins. Rather than adding new verbs, a qualifier extends how a value is transformed when referenced. A plugin providing a `collections` qualifier allows expressions like:

```aro
Compute the <random-item: Collections.pick-random> from the <items>.
Compute the <sorted: Stats.sort> from the <numbers>.
```

Qualifiers are namespaced by the plugin handle (`Collections`, `Stats`) to avoid conflicts between independent plugins. The `QualifierRegistry` resolves these at runtime, dispatching to the appropriate plugin.

---

## 7. Domain Analysis

ARO's constraints are not universally beneficial. Understanding where they help and where they hurt determines when the language is the right choice.

**Business Logic and CRUD APIs.** This is ARO's primary domain. The action vocabulary maps directly to the operations of typical backend services: receive data, validate it, persist it, notify interested parties, respond. A feature set that creates a user record, validates a payment, or updates an inventory count reads like its own specification. Teams in regulated industries — healthcare, finance, compliance — gain the additional property that code is directly auditable by non-engineers.

**Event-Driven Architectures.** ARO's event model is first-class, not an afterthought. The observer pattern, typed events, handler guards, and the event bus are core language features. Applications that react to changes — webhook processors, integration services, audit systems — fit ARO's model naturally.

**Microservices and Internal Tools.** Small, focused applications benefit most from ARO's constraints. A service that handles one domain — user management, notifications, billing — stays coherent as ARO because the vocabulary remains sufficient. Large monolithic applications with diverse concerns are harder to fit into a single action vocabulary.

**DevOps and Build Systems.** Declarative actions like Provision, Deploy, and Configure map to infrastructure operations. ARO's event-driven model suits pipeline triggers. The precedent set by Make and Terraform suggests this domain is viable, though the ecosystem has not yet developed the necessary action vocabulary.

**Data Science and Machine Learning.** This is a poor fit. Iterative experimentation, REPL-driven workflows, and matrix operations require the flexibility and ecosystem depth that Python provides. ARO would impose cost with no corresponding benefit.

**Systems Programming.** The abstraction layer, the runtime overhead, and the absence of low-level memory control make ARO unsuitable for operating system components, device drivers, or performance-critical inner loops.

The following table summarises the assessment:

| Domain | Fit | Reason |
|--------|-----|--------|
| Business Logic / CRUD APIs | Excellent | Vocabulary aligns; constraints reduce complexity |
| Event-Driven Services | Excellent | First-class event model |
| Internal Tools and CLIs | Good | Rapid development with native compilation |
| DevOps / Infrastructure | Moderate | Declarative style fits; vocabulary incomplete |
| Data Science / ML | Poor | Iteration-heavy; ecosystem dependency |
| Systems / Embedded | Poor | No low-level control; abstraction overhead |

---

## 8. Honest Limitations

ARO is pre-alpha software. The following limitations are current facts, not future risks.

**No step debugger.** Errors are reported by the runtime in business terms, which is useful for production but insufficient for complex development scenarios. The approach is to add logging and redeploy — a workflow familiar from early-stage distributed systems, but friction for complex business logic.

**Small ecosystem.** There is no package index comparable to npm or PyPI. The action vocabulary covers common cases; unusual requirements need custom implementations in Swift. This is an investment with high upfront cost.

**No conditional branching.** The `when` guard and `match` expression handle the common cases — executing a statement conditionally, dispatching on a value. Complex nested conditionals require escape to custom actions. Applications with fundamentally conditional logic — tax calculations, permission systems with many rules — will spend more time in the extension layer than in ARO itself.

**Extension overhead.** Adding a custom action requires writing Swift, implementing the `ActionImplementation` protocol, registering the action, and rebuilding. For exploratory development, this friction is real.

**Breaking changes.** Action signatures, preposition semantics, and the plugin ABI are not yet stable. Applications built today may require updates as the language matures. This is an explicit expectation, not a possibility to plan for.

---

## 9. Getting Started

An ARO application is a directory. The minimal structure is a single `.aro` file containing one `Application-Start` feature set:

```aro
(Application-Start: Hello World) {
    Log "Hello, World." to the <console>.
    Return an <OK: status> for the <startup>.
}
```

Run it with:

```bash
aro run ./HelloWorld
```

Build a native binary with:

```bash
aro build ./HelloWorld
./HelloWorld/HelloWorld
```

An HTTP API adds an `openapi.yaml` file at the directory root and feature sets named after the `operationId` values it defines:

```yaml
# openapi.yaml
paths:
  /users:
    get:
      operationId: listUsers
```

```aro
(listUsers: User API) {
    Retrieve the <users> from the <user-repository>.
    Return an <OK: status> with <users>.
}
```

The HTTP server starts automatically when the specification is present. No configuration code is required.

Install a plugin with:

```bash
aro add git@github.com:arolang/plugin-sqlite.git
```

The plugin is compiled on installation and available to all feature sets in the application.

---

## 10. Summary

ARO is a language built around three commitments: statements read like sentences, programs run as events, and errors report themselves.

The sentence commitment comes from FDD's insight that business language can be formally structured. The event commitment comes from the observation that business systems are inherently reactive. The error commitment comes from the recognition that most error handling is defensive boilerplate that obscures the intent of the code.

These commitments impose real constraints. The language cannot express arbitrary algorithms. The extension mechanism requires stepping outside the language. The ecosystem is thin. These are not problems to be solved; they are trade-offs to be understood. A language that says no to some things enables it to say yes, clearly and reliably, to others.

For teams building event-driven business services, for organisations that need code their business stakeholders can read, and for developers who want their architecture to enforce the patterns they would impose by convention anyway, those trade-offs are favourable. For everyone else, ARO is an interesting design point in the space of constrained languages — a reminder that the most powerful thing a language can do is decide what it will not express.

---

*For the full specification, see the `Proposals/` directory. For worked examples, see `Examples/`. For the complete language reference, see The Language Guide in `Book/TheLanguageGuide/`.*

---

```
ARO · pre-alpha · March 2026
```
