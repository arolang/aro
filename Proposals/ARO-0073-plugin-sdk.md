# Proposal: Plugin SDK & Developer Experience

**Proposal-ID:** ARO-0073
**Author:** ARO Language Team
**Status:** Draft
**Created:** 2026-04-11
**Updated:** 2026-04-11
**Requires:** ARO-0045 (Package Manager), ARO-0016 (Interoperability)

---

## Summary

This proposal introduces **language-native SDK libraries** for Swift, Rust, C, C++, and Python that hide the raw C ABI, JSON serialization, and memory management behind idiomatic, ergonomic APIs. Plugin authors write natural code in their language of choice; the SDK generates the required `aro_plugin_*` exports automatically.

The proposal also **replaces the three existing plugin ABIs** (actions, services, qualifiers) with a single clean contract, introduces **system object support**, **qualifier chaining and parameters**, **lifecycle hooks**, a **plugin scaffolding CLI** (`aro new plugin`), and the **Invoke mechanism** for plugins to call back into ARO feature sets.

Since ARO is pre-1.0, we favor a clean API over backward compatibility. The old service ABI (`aro_plugin_init` + `_call` with out-pointers) and the separate `aro_plugin_execute` stub requirement for qualifier-only plugins are removed entirely. Existing example plugins will be rewritten. The Plugin Guide book will be updated to match.

---

## Motivation

### The Problem: Ceremony Over Substance

An analysis of all nine plugin examples reveals a striking imbalance between business logic and boilerplate:

| Language | Logic | Ceremony | Worst Offender |
|----------|-------|----------|----------------|
| C (qualifiers) | ~5% | ~95% | Hand-rolled JSON array parsing |
| Swift (actions) | ~20% | ~80% | NSDictionary workarounds, `@_cdecl` |
| C (actions) | ~30% | ~70% | Manual `strstr`-based JSON extraction |
| Swift (services) | ~45% | ~55% | Foundation bridging across dylib boundary |
| Rust | ~65% | ~35% | `unsafe` blocks for CString FFI |
| Python | ~80% | ~20% | Minimal -- but inconsistent contract |

A C plugin author who wants to implement a simple "first element" qualifier must write **~150 lines of pointer arithmetic** to parse a JSON array. A Swift plugin author must know about `NSDictionary` workarounds for cross-binary Foundation bridging. A Rust author needs six `unsafe` blocks for string conversions. None of this has anything to do with the plugin's actual purpose.

### Specific Pain Points

1. **No SDK or helper library.** Every plugin hand-rolls JSON serialization, C ABI exports, and memory management from scratch.

2. **Three incompatible ABI patterns** with no documentation on when to use which:
   - **Actions ABI**: `aro_plugin_execute(action, input_json) -> result_json`
   - **Services ABI**: `aro_plugin_init()` + `service_call(method, args, &result) -> Int32`
   - **Qualifiers ABI**: `aro_plugin_qualifier(name, input_json) -> result_json`

3. **C/C++ plugins must hand-roll JSON parsing.** The `find_json_string` / `extract_json_array` helpers in examples are fragile -- no escape handling, fixed-size buffers, no nested object support.

4. **Swift plugins have Foundation bridging bugs.** Two separate examples document workarounds: `NSDictionary` instead of `Dictionary` for `aro_plugin_info`, and manual `escapeJSON` instead of Foundation string methods.

5. **Qualifier-only plugins must implement a stub `aro_plugin_execute`** that returns an error. Unnecessary ceremony.

6. **Python uses a fundamentally different contract** (per-function `aro_action_*`, dict return type) from native plugins (single `aro_plugin_execute`, JSON string return). Knowledge doesn't transfer between languages.

7. **No type safety.** All data flows through untyped JSON dictionaries with no schemas, code generation, or typed interfaces.

8. **No event system integration for plugins.** Plugins cannot subscribe to or emit domain events through a clean API.

9. **Plugin qualifiers cannot accept parameters.** Built-in qualifiers like `clip` and `take` accept arguments via the `with` clause, but plugin qualifiers receive only the bare value.

10. **No qualifier chaining.** There is no way to compose multiple qualifiers in a single expression.

11. **No system object support.** Plugins cannot provide custom system objects (like a Redis store) through the current ABI.

12. **No plugin-to-runtime invocation.** Plugins cannot call ARO feature sets, making hybrid plugin architectures difficult.

### The Vision

A Swift plugin author should be able to write:

```swift
import AROPluginSDK

@AROPlugin(handle: "Greeting")
struct GreetingPlugin {
    @Action(verbs: ["Greet"], prepositions: [.with])
    func greet(input: ActionInput) -> ActionOutput {
        let name = input.string("name") ?? "World"
        return .success(["greeting": "Hello, \(name)!"])
    }
}
```

A Rust plugin author should be able to write:

```rust
use aro_plugin_sdk::prelude::*;

#[aro_plugin(handle = "CSV")]
mod csv_plugin {
    #[action(verbs = ["ParseCSV"], prepositions = ["from"])]
    fn parse_csv(input: &Input) -> Result<Output> {
        // just the parsing logic
    }
}
```

A C or C++ plugin author should be able to write:

```c
#include "aro_plugin_sdk.h"

ARO_PLUGIN("Hash", "1.0.0");

ARO_ACTION("ComputeHash", ROLE_OWN, PREP_FROM) {
    const char* input = aro_input_string(ctx, "data");
    uint32_t hash = djb2(input);
    aro_output_int(ctx, "hash", hash);
    return aro_ok(ctx);
}
```

A Python plugin author should be able to write:

```python
from aro_plugin_sdk import plugin, action, qualifier

@plugin(handle="Stats")
class StatsPlugin:
    @qualifier(input_types=["List"])
    def average(self, values: list) -> float:
        return sum(values) / len(values)
```

---

## Proposed Solution

### 1. Clean Plugin ABI

We replace the three existing ABIs with one clean contract. Since ARO is pre-1.0, there is no backward compatibility obligation. The old service ABI (`aro_plugin_init` + `_call` with 3-parameter out-pointer signature) is removed entirely. The `AROService` protocol and `ServiceRegistry` are deprecated and replaced by the unified plugin ABI -- the same functionality is achieved more cleanly through plugin actions and the `Call` action routing.

#### 1.1 The C ABI

```
+--------------------------------------------------------------------+
|                      REQUIRED                                       |
+--------------------------------------------------------------------+
|  char* aro_plugin_info(void)                                       |
|    Returns JSON metadata describing everything the plugin provides  |
+--------------------------------------------------------------------+
|  void  aro_plugin_free(char* ptr)                                  |
|    Frees any string returned by the plugin                         |
+--------------------------------------------------------------------+
|                                                                    |
|                   OPTIONAL (based on what you provide)             |
+--------------------------------------------------------------------+
|  void  aro_plugin_init(void)                                       |
|    One-time initialization (DB connections, model loading, etc.)    |
+--------------------------------------------------------------------+
|  void  aro_plugin_shutdown(void)                                   |
|    Cleanup on unload (close connections, flush buffers, etc.)       |
+--------------------------------------------------------------------+
|  char* aro_plugin_execute(const char* action, const char* input)   |
|    Only needed if you provide actions or services                  |
+--------------------------------------------------------------------+
|  char* aro_plugin_qualifier(const char* name, const char* input)   |
|    Only needed if you provide qualifiers                           |
+--------------------------------------------------------------------+
|  void  aro_plugin_on_event(const char* event_type, const char* data)|
|    Only needed if you subscribe to events                          |
+--------------------------------------------------------------------+
|  char* aro_object_read(const char* id, const char* qualifier)      |
|    Only needed if you provide system objects                       |
+--------------------------------------------------------------------+
|  char* aro_object_write(const char* id, const char* qualifier,     |
|                          const char* value)                        |
|    Only needed if you provide writable system objects               |
+--------------------------------------------------------------------+
|  char* aro_object_list(const char* pattern)                        |
|    Only needed if you provide enumerable system objects             |
+--------------------------------------------------------------------+
|  char* aro_plugin_invoke(const char* feature_set,                  |
|                           const char* input)                       |
|    Runtime-provided: plugins call this to invoke ARO feature sets   |
+--------------------------------------------------------------------+
```

Key design choices:
- `aro_plugin_info` and `aro_plugin_free` are the **only** required exports
- `aro_plugin_execute` is **not** required for qualifier-only or system-object-only plugins
- Services route through `aro_plugin_execute` with action name `"service:<method>"`
- `aro_plugin_init` / `aro_plugin_shutdown` are lifecycle hooks for stateful plugins
- System objects have dedicated `aro_object_read` / `aro_object_write` / `aro_object_list` functions
- `aro_plugin_invoke` is a **callback** provided by the runtime, enabling plugins to call ARO feature sets

#### 1.2 Unified Info JSON Schema

```json
{
  "name": "plugin-name",
  "version": "1.0.0",
  "actions": [
    {
      "name": "ComputeHash",
      "verbs": ["hash", "computehash"],
      "role": "own",
      "prepositions": ["from", "with"],
      "description": "Computes a hash of the input data"
    }
  ],
  "services": [
    {
      "name": "sqlite",
      "methods": ["query", "execute", "connect", "disconnect"],
      "description": "SQLite database service"
    }
  ],
  "qualifiers": [
    {
      "name": "reverse",
      "input_types": ["List", "String"],
      "accepts_parameters": true,
      "description": "Reverses the order of elements"
    }
  ],
  "system_objects": [
    {
      "identifier": "redis",
      "capabilities": ["readable", "writable", "enumerable", "watchable"],
      "description": "Redis key-value store"
    }
  ],
  "events": {
    "emits": ["DataProcessed", "CacheInvalidated"],
    "subscribes": ["UserCreated", "OrderPlaced"]
  },
  "deprecations": [
    {
      "feature": "action:OldHash",
      "message": "Use ComputeHash instead",
      "since": "1.2.0",
      "remove_in": "2.0.0"
    }
  ]
}
```

Services are now **declared in `aro_plugin_info`** alongside actions and qualifiers. The runtime routes `Call the <result> from the <sqlite: query>` to `aro_plugin_execute("service:query", input_json)`. No separate `_call` symbol needed.

#### 1.3 What Gets Removed

The following are removed from the runtime and replaced by the clean ABI:

- **`aro_plugin_init` returning service metadata** (the old service discovery pattern). Replaced by `aro_plugin_info` which declares everything.
- **3-parameter service function signature** (`method, args, &result -> Int32`). Replaced by routing through `aro_plugin_execute("service:<method>", input)`.
- **`AROService` protocol** and `ServiceRegistry`. The same functionality is achieved via plugin actions and the `Call` action. This removes code complexity without losing any capability.
- **`aro_plugin_execute` stub requirement** for qualifier-only plugins.

Existing example plugins (`SQLiteExample`, `ZipService`, `GreetingPlugin`, `HashPluginDemo`, `CSVProcessor`, `MarkdownRenderer`, all qualifier plugins) will be rewritten to use the new SDK. The Plugin Guide book chapters will be updated to match.

#### 1.4 Input JSON: Context and Descriptors

The runtime passes rich context to plugins via the input JSON. The SDK exposes this through typed helpers:

```json
{
  "data": "the primary object value",
  "object": "alias for data (backward compat)",
  "qualifier": "the result qualifier (e.g., sha256)",
  "preposition": "from",
  "result": {
    "base": "digest",
    "qualifiers": ["sha256"],
    "specifiers": ["sha256"]
  },
  "source": {
    "base": "password",
    "specifiers": []
  },
  "_context": {
    "requestId": "req-abc-123",
    "featureSet": "Secure Password: User Registration",
    "businessActivity": "User Registration"
  },
  "_with": {
    "encoding": "hex",
    "rounds": 10
  }
}
```

The `result` and `source` fields expose the full **ResultDescriptor** and **ObjectDescriptor** models (base, qualifiers, specifiers). The `_context` prefix passes execution context information. The `_with` field contains parameters from the `with { }` clause.

SDK helpers provide typed access to all of this:

```swift
// Swift SDK
input.result.base          // "digest"
input.result.qualifiers    // ["sha256"]
input.source.base          // "password"
input.context.requestId    // "req-abc-123"
input.with.string("encoding")  // "hex"
input.with.int("rounds")       // 10
input.preposition          // .from
```

#### 1.5 Preposition-Based Dispatch

Different prepositions can trigger different behavior within an action. The SDK exposes the preposition and the runtime passes it in the input JSON:

```swift
@Action(verbs: ["Transform"], role: .own, prepositions: [.from, .to, .into, .as])
func transform(input: ActionInput) -> ActionOutput {
    switch input.preposition {
    case .from:  return convertFormat(input)     // Transform <out> from <xml>
    case .to:    return applyTransform(input)     // Transform <data> to <target>
    case .into:  return mapToType(input)          // Transform <data> into <type>
    case .as:    return encode(input)             // Transform <data> as <format>
    default:     return .error("Unsupported preposition")
    }
}
```

---

### 2. Qualifier Improvements

#### 2.1 Parameterized Qualifiers

Plugin qualifiers can now accept parameters via the `with` clause, just like built-in qualifiers (`clip`, `take`):

```aro
(* Plugin qualifier with parameters *)
Compute the <top-items: stats.top> from the <scores> with { count: 5 }.
Compute the <clipped: text.truncate> from the <message> with { maxLength: 100, suffix: "..." }.
```

The `with` clause parameters are passed to the qualifier function in the input JSON under the `"_with"` key:

```json
{
  "value": [95, 87, 72, 100, 63, 91],
  "type": "List",
  "_with": { "count": 5 }
}
```

SDK qualifier declarations indicate parameter support:

```swift
@Qualifier(inputTypes: [.list], acceptsParameters: true)
func top(value: [Any], params: QualifierParams) -> [Any] {
    let count = params.int("count") ?? 3
    return Array(value.sorted(by: >).prefix(count))
}
```

```rust
#[qualifier(input_types = ["List"], accepts_parameters = true)]
fn top(value: Value, params: &Params) -> Result<Value> {
    let count = params.int("count").unwrap_or(3) as usize;
    // ...
}
```

```c
ARO_QUALIFIER_WITH_PARAMS("top", "List", "Top N elements") {
    int count = aro_qualifier_param_int(ctx, "count", 3);
    aro_array* arr = aro_qualifier_array(ctx);
    // ...
}
```

```python
@qualifier(input_types=["List"], accepts_parameters=True)
def top(self, values, params):
    count = params.int("count", default=3)
    return sorted(values, reverse=True)[:count]
```

#### 2.2 Qualifier Chaining (Composition)

Multiple qualifiers can be chained in a single expression using the pipe syntax:

```aro
(* Chain: sort the list, then take the first 3 *)
Compute the <top3: stats.sort | list.take> from the <scores> with { count: 3 }.

(* Chain: reverse, then pick a random element *)
Compute the <surprise: collections.reverse | collections.pick-random> from the <items>.
```

The runtime evaluates qualifiers left-to-right. Each qualifier's output becomes the next qualifier's input. Parameters from the `with` clause are passed to all qualifiers in the chain (each qualifier reads only the parameters it recognizes).

Implementation: The parser recognizes `|` within specifier positions. The `QualifierRegistry` receives an ordered list of qualifier names and applies them sequentially.

#### 2.3 Qualifier Conflict Resolution

If two plugins register the same qualifier name under the same namespace, this is a load-time error. The plugin author must ensure unique qualifier names within their namespace.

If an application needs two plugins that happen to share a qualifier name, the application's manifest can **alias** one plugin's handle:

```yaml
# In the application's aro.yaml or plugin configuration
plugins:
  plugin-stats-v1:
    alias: StatsV1       # Override the plugin's handle
  plugin-stats-v2:
    alias: StatsV2
```

This gives each plugin a distinct namespace: `StatsV1.sort` vs `StatsV2.sort`.

#### 2.4 Ambiguity Resolution

When a qualifier name matches both a data field and a built-in operation (e.g., a field called `length`), the resolution order is:

1. **Plugin qualifiers** (namespaced, e.g., `collections.length`) -- always unambiguous
2. **Built-in operations** (unqualified, e.g., `length`) -- if no field matches
3. **Data field access** -- if the symbol table contains a matching field

This is the existing behavior, documented here for clarity. The recommendation: always use namespaced qualifiers (`handle.qualifier`) to avoid ambiguity.

#### 2.5 Unified Qualifier Registry

Built-in qualifiers (`hash`, `length`, `uppercase`, `lowercase`, `clip`, `take`, `date`, `format`, `distance`, `intersect`, `difference`, `union`) are registered in `QualifierRegistry` alongside plugin qualifiers. This provides a **single source of truth** for all available qualifiers.

The `aro actions list` command (see Section 9) also lists all registered qualifiers with their source (built-in vs plugin name).

---

### 3. System Objects

Plugins can provide custom system objects that integrate with ARO's Source/Sink model. System objects appear as native ARO objects:

```aro
(* Using a Redis system object provided by a plugin *)
Store the <user-data> to the <redis: users/42>.
Retrieve the <cached> from the <redis: sessions/abc>.
Log <redis: stats> to the <console>.
```

#### 3.1 System Object Capabilities

Each system object declares capabilities in `aro_plugin_info`:

| Capability | C ABI Function | ARO Usage |
|------------|---------------|-----------|
| `readable` | `aro_object_read(id, qualifier)` | `Retrieve the <x> from the <redis: key>` |
| `writable` | `aro_object_write(id, qualifier, value)` | `Store the <x> to the <redis: key>` |
| `enumerable` | `aro_object_list(pattern)` | `Retrieve the <keys> from the <redis: *>` |
| `watchable` | Events via `aro_plugin_on_event` | Emits change events automatically |

#### 3.2 SDK Support

```swift
@SystemObject(identifier: "redis", capabilities: [.readable, .writable, .enumerable])
func redis(operation: ObjectOperation) -> ActionOutput {
    switch operation {
    case .read(let id, let qualifier):
        let value = redisClient.get("\(qualifier)/\(id)")
        return .success(["value": value])
    case .write(let id, let qualifier, let value):
        redisClient.set("\(qualifier)/\(id)", value: value)
        return .success(["stored": true])
    case .list(let pattern):
        let keys = redisClient.keys(pattern)
        return .success(["keys": keys])
    }
}
```

```rust
#[system_object(identifier = "redis", capabilities = ["readable", "writable", "enumerable"])]
fn redis(op: ObjectOp) -> Result<Output> {
    match op {
        ObjectOp::Read { id, qualifier } => { /* ... */ }
        ObjectOp::Write { id, qualifier, value } => { /* ... */ }
        ObjectOp::List { pattern } => { /* ... */ }
    }
}
```

```c
ARO_SYSTEM_OBJECT("redis", CAP_READABLE | CAP_WRITABLE | CAP_ENUMERABLE) {
    if (op == ARO_OP_READ) {
        const char* key = aro_object_id(ctx);
        // ...
    } else if (op == ARO_OP_WRITE) {
        const char* key = aro_object_id(ctx);
        const char* value = aro_object_value(ctx);
        // ...
    }
}
```

---

### 4. Plugin-to-Runtime Invocation

Hybrid plugins (native code + `.aro` files) need a way for native code to call back into ARO feature sets. The `aro_plugin_invoke` callback enables this:

#### 4.1 The Invoke Callback

The runtime provides a function pointer to the plugin during initialization:

```c
// Runtime sets this before calling any plugin function
typedef char* (*aro_invoke_fn)(const char* feature_set, const char* input_json);
void aro_plugin_set_invoke(aro_invoke_fn fn);
```

Plugins call this to invoke ARO feature sets:

```c
// From within a plugin action:
char* result = aro_plugin_invoke("Validate Order: Order Validation", input_json);
// Parse result, use it in the plugin's logic
aro_plugin_free(result);
```

#### 4.2 SDK Wrappers

```swift
// Swift SDK
let result = try ARORuntime.invoke("Validate Order: Order Validation", input: ["order": orderData])
```

```rust
// Rust SDK
let result = aro_runtime::invoke("Validate Order: Order Validation", &input)?;
```

```python
# Python SDK
result = aro_runtime.invoke("Validate Order: Order Validation", {"order": order_data})
```

This enables the hybrid plugin pattern described in Plugin Guide Chapter 14: native code handles computation (Argon2 hashing, JWT tokens), while ARO feature sets handle business logic (authentication workflows, validation rules).

---

### 5. Language SDKs

Each SDK is a thin library that:
1. Generates the `aro_plugin_*` C ABI exports
2. Handles JSON serialization/deserialization
3. Manages memory (allocation and freeing)
4. Provides typed input/output access including descriptors and context
5. Emits the `aro_plugin_info` response from declarations
6. Provides standard error codes and domain-specific error categories
7. Supports async operations

#### 5.1 Swift SDK (`AROPluginSDK`)

Distributed as a Swift package. Plugin authors add it as a dependency.

**Package.swift for a plugin:**
```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GreetingPlugin",
    products: [
        .library(name: "GreetingPlugin", type: .dynamic, targets: ["GreetingPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/AROLang/aro-plugin-sdk-swift.git", from: "1.0.0")
    ],
    targets: [
        .target(name: "GreetingPlugin", dependencies: ["AROPluginSDK"])
    ]
)
```

Note: `type: .dynamic` is required -- without it SPM builds a static library that cannot be loaded at runtime. Simple single-file plugins (no dependencies) can also be placed as a bare `.swift` file in `Sources/` and ARO will compile it with `swiftc` automatically.

**Plugin implementation:**
```swift
import AROPluginSDK

@AROPlugin(handle: "Greeting", version: "1.0.0")
struct GreetingPlugin {

    // -- Lifecycle --

    @OnInit
    static func setup() {
        // One-time initialization (DB connections, model loading)
    }

    @OnShutdown
    static func cleanup() {
        // Cleanup on unload (close connections, flush buffers)
    }

    // -- Actions --

    @Action(verbs: ["Greet"], role: .own, prepositions: [.with])
    func greet(input: ActionInput) -> ActionOutput {
        let name = input.string("name") ?? input.string("data") ?? "World"
        return .success(["greeting": "Hello, \(name)!"])
    }

    // -- Qualifiers --

    @Qualifier(inputTypes: [.list], acceptsParameters: true)
    func top(value: [Any], params: QualifierParams) -> [Any] {
        let count = params.int("count") ?? 3
        return Array((value as? [Int] ?? []).sorted(by: >).prefix(count))
    }

    // -- Services --

    @Service(methods: ["connect", "query", "disconnect"])
    func database(method: String, input: ActionInput) -> ActionOutput {
        switch method {
        case "connect": return .success(["connected": true])
        case "query":   return .success(["rows": []])
        default:        return .error(.unknownMethod(method))
        }
    }

    // -- System Objects --

    @SystemObject(identifier: "cache", capabilities: [.readable, .writable])
    func cache(operation: ObjectOperation) -> ActionOutput {
        switch operation {
        case .read(let id, let qualifier):
            return .success(["value": memoryCache["\(qualifier)/\(id)"]])
        case .write(let id, let qualifier, let value):
            memoryCache["\(qualifier)/\(id)"] = value
            return .success(["stored": true])
        default:
            return .error(.unsupportedOperation)
        }
    }

    // -- Events --

    @OnEvent("UserCreated")
    func handleUserCreated(event: EventData) {
        let userId = event.string("userId") ?? "unknown"
        print("User created: \(userId)")
    }

    // -- Async Support --

    @Action(verbs: ["FetchData"], role: .request, prepositions: [.from])
    func fetchData(input: ActionInput) async -> ActionOutput {
        // The SDK bridges async/await to the synchronous C ABI automatically
        let url = input.string("url") ?? ""
        let data = await httpClient.get(url)
        return .success(["data": data])
    }
}
```

The `@AROPlugin` macro generates all `@_cdecl` exports, handles the `NSDictionary` workaround internally, bridges `async` functions via `Task` + semaphore automatically, and manages memory with C `malloc`/`free` to avoid Foundation bridging issues.

**SDK helper types:**

```swift
/// Full access to plugin input data including descriptors and context
public struct ActionInput: Sendable {
    // -- Data access --
    public func string(_ key: String) -> String?
    public func int(_ key: String) -> Int?
    public func double(_ key: String) -> Double?
    public func bool(_ key: String) -> Bool?
    public func array(_ key: String) -> [Any]?
    public func dict(_ key: String) -> [String: Any]?

    // -- Descriptors --
    public var result: Descriptor   // { base, qualifiers, specifiers }
    public var source: Descriptor   // { base, specifiers }
    public var preposition: Preposition

    // -- Context --
    public var context: ExecutionInfo  // { requestId, featureSet, businessActivity }

    // -- With-clause parameters --
    public var with: QualifierParams
}

/// Standard error codes (ARO Appendix C)
public enum PluginErrorCode: Int {
    case success = 0
    case invalidInput = 1
    case notFound = 2
    case permissionDenied = 3
    case timeout = 4
    case connectionFailed = 5
    case executionFailed = 6
    case invalidState = 7
    case resourceExhausted = 8
    case unsupported = 9
    case rateLimited = 10
}

/// Domain-specific error categories
public enum PluginErrorCategory: String {
    case validation     // VALIDATION_MISSING_FIELD, VALIDATION_INVALID_FORMAT
    case io             // IO_FILE_NOT_FOUND, IO_PERMISSION_DENIED
    case authentication // AUTH_INVALID_TOKEN, AUTH_EXPIRED
    case rateLimiting   // RATE_LIMIT_EXCEEDED, RATE_LIMIT_QUOTA
}

/// Plugin output with error support
public enum ActionOutput: Sendable {
    case success([String: Any])
    case error(PluginErrorCode, String? = nil, [String: Any]? = nil)

    /// Emit an event alongside the result
    func emit(_ eventType: String, data: [String: Any]) -> ActionOutput

    /// Invoke an ARO feature set from within the plugin
    static func invoke(_ featureSet: String, input: [String: Any]) throws -> [String: Any]
}
```

#### 5.2 Rust SDK (`aro-plugin-sdk`)

Distributed as a crate (initially via git dependency, later via crates.io).

**Cargo.toml:**
```toml
[package]
name = "my-csv-plugin"
version = "1.0.0"

[lib]
crate-type = ["cdylib"]

[dependencies]
aro-plugin-sdk = { git = "https://github.com/AROLang/aro-plugin-sdk-rust.git" }
serde_json = "1.0"

[profile.release]
lto = true
codegen-units = 1
panic = "abort"       # prevents panics from crossing the FFI boundary
opt-level = "z"
```

**Plugin implementation:**
```rust
use aro_plugin_sdk::prelude::*;

#[aro_plugin(handle = "CSV", version = "1.0.0")]
mod csv_plugin {
    use super::*;

    #[init]
    fn setup() {
        // One-time initialization
    }

    #[shutdown]
    fn cleanup() {
        // Cleanup on unload
    }

    #[action(verbs = ["ParseCSV", "ReadCSV"], role = "request", prepositions = ["from"])]
    fn parse_csv(input: &Input) -> Result<Output> {
        let data = input.string("data")?;
        let delimiter = input.with_params().string("delimiter").unwrap_or(",".into());

        let rows: Vec<Vec<String>> = data
            .lines()
            .map(|line| line.split(&*delimiter).map(String::from).collect())
            .collect();

        Ok(Output::new()
            .set("rows", &rows)
            .set("count", rows.len())
            .set("headers", &rows[0]))
    }

    #[qualifier(input_types = ["List"], accepts_parameters = true)]
    fn top(value: Value, params: &Params) -> Result<Value> {
        let count = params.int("count").unwrap_or(3) as usize;
        let mut arr = value.as_array()?.clone();
        arr.sort_by(|a, b| b.partial_cmp(a).unwrap_or(std::cmp::Ordering::Equal));
        arr.truncate(count);
        Ok(Value::Array(arr))
    }

    #[system_object(identifier = "csv-store", capabilities = ["readable", "writable"])]
    fn csv_store(op: ObjectOp) -> Result<Output> {
        match op {
            ObjectOp::Read { id, qualifier } => { /* ... */ }
            ObjectOp::Write { id, qualifier, value } => { /* ... */ }
            _ => Err(PluginError::unsupported("list not supported"))
        }
    }

    #[on_event("DataImported")]
    fn handle_import(event: &EventData) {
        let source = event.string("source").unwrap_or_default();
        println!("Data imported from: {source}");
    }
}
```

All `unsafe` blocks and `catch_unwind` wrappers are encapsulated in `aro_plugin_sdk::ffi`. The developer writes zero unsafe code. The `panic = "abort"` profile setting prevents panics from crossing the FFI boundary.

#### 5.3 C SDK (`aro_plugin_sdk.h`)

A **single header file** (stb-style) that plugin authors `#include`. No build system dependency -- just drop the header into your project. Works for both C and multi-file plugin structures.

**aro_plugin_sdk.h** provides:
- JSON parsing helpers (using a bundled minimal JSON parser)
- Memory management (arena allocator for response building)
- Declarative macros for plugin registration
- Standard error codes

**Plugin implementation:**

```c
#include "aro_plugin_sdk.h"

/* Declare the plugin */
ARO_PLUGIN("Hash", "1.0.0");

/* Lifecycle */
ARO_INIT() {
    /* One-time initialization */
}

ARO_SHUTDOWN() {
    /* Cleanup */
}

/* Declare and implement actions */
ARO_ACTION("ComputeHash", ROLE_OWN, PREP_FROM) {
    const char* data = aro_input_string(ctx, "data");
    const char* algorithm = aro_input_string(ctx, "qualifier");
    if (!algorithm) algorithm = "djb2";

    /* Access preposition for dispatch */
    const char* prep = aro_input_preposition(ctx);

    /* Access with-clause parameters */
    const char* encoding = aro_with_string(ctx, "encoding", "hex");

    uint32_t result;
    if (strcmp(algorithm, "djb2") == 0) {
        result = hash_djb2(data);
    } else if (strcmp(algorithm, "fnv1a") == 0) {
        result = hash_fnv1a(data);
    } else {
        return aro_error(ctx, ARO_ERR_INVALID_INPUT, "Unknown algorithm: %s", algorithm);
    }

    aro_output_int(ctx, "hash", result);
    aro_output_string(ctx, "algorithm", algorithm);
    return aro_ok(ctx);
}

/* Qualifier with parameters */
ARO_QUALIFIER_WITH_PARAMS("top", "List", "Returns top N elements") {
    int count = aro_qualifier_param_int(ctx, "count", 3);
    aro_array* arr = aro_qualifier_array(ctx);
    /* sort and truncate... */
    return aro_qualifier_result_array(ctx, result_arr);
}

/* System object */
ARO_SYSTEM_OBJECT("hash-cache", CAP_READABLE | CAP_WRITABLE) {
    if (op == ARO_OP_READ) {
        const char* key = aro_object_id(ctx);
        /* ... */
    } else if (op == ARO_OP_WRITE) {
        /* ... */
    }
    return aro_ok(ctx);
}
```

**The `aro_ctx` helpers:**

```c
/* Reading input */
const char* aro_input_string(aro_ctx* ctx, const char* key);
int64_t     aro_input_int(aro_ctx* ctx, const char* key);
double      aro_input_double(aro_ctx* ctx, const char* key);
int         aro_input_bool(aro_ctx* ctx, const char* key);
aro_array*  aro_input_array(aro_ctx* ctx, const char* key);

/* Descriptors */
const char* aro_input_result_base(aro_ctx* ctx);
const char* aro_input_source_base(aro_ctx* ctx);
const char* aro_input_preposition(aro_ctx* ctx);

/* Context */
const char* aro_context_string(aro_ctx* ctx, const char* key);  /* e.g., "requestId" */

/* With-clause parameters */
const char* aro_with_string(aro_ctx* ctx, const char* key, const char* default_val);
int64_t     aro_with_int(aro_ctx* ctx, const char* key, int64_t default_val);

/* Array access */
size_t      aro_array_length(aro_array* arr);
const char* aro_array_string(aro_array* arr, size_t index);
int64_t     aro_array_int(aro_array* arr, size_t index);

/* Writing output */
void aro_output_string(aro_ctx* ctx, const char* key, const char* value);
void aro_output_int(aro_ctx* ctx, const char* key, int64_t value);
void aro_output_double(aro_ctx* ctx, const char* key, double value);
void aro_output_bool(aro_ctx* ctx, const char* key, int value);
void aro_output_array(aro_ctx* ctx, const char* key, aro_array* value);

/* Results with standard error codes */
const char* aro_ok(aro_ctx* ctx);
const char* aro_error(aro_ctx* ctx, int code, const char* fmt, ...);

/* Standard error codes */
#define ARO_ERR_SUCCESS           0
#define ARO_ERR_INVALID_INPUT     1
#define ARO_ERR_NOT_FOUND         2
#define ARO_ERR_PERMISSION_DENIED 3
#define ARO_ERR_TIMEOUT           4
#define ARO_ERR_CONNECTION_FAILED 5
#define ARO_ERR_EXECUTION_FAILED  6
#define ARO_ERR_INVALID_STATE     7
#define ARO_ERR_RESOURCE_EXHAUSTED 8
#define ARO_ERR_UNSUPPORTED       9
#define ARO_ERR_RATE_LIMITED      10

/* Invoke ARO feature sets */
const char* aro_invoke(aro_ctx* ctx, const char* feature_set, const char* input_json);
```

Memory for all returned strings uses an **arena allocator** that is freed in bulk by `aro_plugin_free`. No individual `malloc`/`free` tracking needed by the plugin author.

#### 5.4 C++ SDK (`aro_plugin_sdk.hpp`)

A C++ wrapper around the C SDK header, providing RAII, exception safety, and modern C++ idioms. Distributed as a **header-only library** (two files: `aro_plugin_sdk.h` + `aro_plugin_sdk.hpp`).

```cpp
#include "aro_plugin_sdk.hpp"

ARO_PLUGIN("Audio", "1.0.0");

// C++ plugins use the same macros as C, but gain RAII wrappers
ARO_ACTION("AnalyzeAudio", ROLE_OWN, PREP_FROM) {
    // C++ exception safety: exceptions are caught at the boundary
    // and converted to ARO error responses automatically
    auto data = aro::input_string(ctx, "data");
    auto sample_rate = aro::with_int(ctx, "sampleRate", 44100);

    // RAII resource management
    auto fft = std::make_unique<FFTProcessor>(sample_rate);
    auto spectrum = fft->analyze(data);

    // Use C++ containers freely -- the SDK serializes them
    std::vector<double> peaks = spectrum.find_peaks();
    aro::output_array(ctx, "peaks", peaks);
    aro::output_double(ctx, "dominantFrequency", spectrum.dominant());
    return aro_ok(ctx);
}

// Qualifiers work the same way
ARO_QUALIFIER("fft", "List", "Compute FFT of signal data") {
    auto values = aro::qualifier_array<double>(ctx);
    auto result = compute_fft(values);
    return aro::qualifier_result_array(ctx, result);
}
```

The C++ SDK adds:
- `aro::` namespace wrappers with type-safe templates
- Automatic `try/catch` around the `extern "C"` boundary (all C++ exceptions are caught and converted to ARO error responses)
- `std::vector`, `std::string`, `std::map` serialization
- RAII scope guards for resource cleanup

Plugins compile with `clang++` or `g++` and link with `-lstdc++`. The SDK handles the `extern "C"` wrapping.

#### 5.5 Python SDK (`aro-plugin-sdk`)

Distributed via pip. Plugin authors install it with `pip install aro-plugin-sdk`.

**Plugin implementation:**

```python
from aro_plugin_sdk import plugin, action, qualifier, service, on_event, system_object
from aro_plugin_sdk import ErrorCode

@plugin(handle="Markdown", version="1.0.0")
class MarkdownPlugin:

    def on_init(self):
        """One-time initialization."""
        self.render_count = 0

    def on_shutdown(self):
        """Cleanup on unload."""
        pass

    @action(verbs=["ToHTML", "RenderMarkdown"], role="own", prepositions=["from"])
    def to_html(self, input):
        """Convert markdown text to HTML."""
        import re
        text = input.string("data")
        text = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', text)
        text = re.sub(r'\*(.+?)\*', r'<em>\1</em>', text)
        self.render_count += 1
        return {"html": text, "renderCount": self.render_count}

    @qualifier(input_types=["List"], accepts_parameters=True)
    def sort(self, values, params=None):
        """Sort a list of values."""
        reverse = params.bool("descending", default=False) if params else False
        return sorted(values, key=str, reverse=reverse)

    @system_object(identifier="render-cache", capabilities=["readable", "writable"])
    def render_cache(self, operation):
        if operation.type == "read":
            return {"value": self._cache.get(operation.id)}
        elif operation.type == "write":
            self._cache[operation.id] = operation.value
            return {"stored": True}
```

**Persistent mode** -- the default for SDK-based plugins. The plugin runs as a long-lived subprocess communicating over stdin/stdout with JSON-line protocol:

```
+-----------+     JSON lines over stdin/stdout     +----------------+
|  ARO      | ──────────────────────────────────── |  Python Plugin |
|  Runtime  |  {"id":1,"type":"execute",...}  ───> |  (persistent   |
|           |  <───  {"id":1,"result":{...}}       |   subprocess)  |
|           |  {"id":2,"type":"event",...}    ───>  |                |
+-----------+                                       +----------------+
```

**GPU acceleration support** for ML plugins:

```python
from aro_plugin_sdk import plugin, action
import torch

@plugin(handle="ML", version="1.0.0")
class MLPlugin:

    def on_init(self):
        """Detect GPU, load model with appropriate settings."""
        self.device = "cuda" if torch.cuda.is_available() else "cpu"

        if self.device == "cuda":
            from transformers import BitsAndBytesConfig
            quantization = BitsAndBytesConfig(load_in_4bit=True)
            self.model = AutoModel.from_pretrained("model", quantization_config=quantization)
        else:
            self.model = AutoModel.from_pretrained("model")

    @action(verbs=["Embed"], role="own", prepositions=["from"])
    def embed(self, input):
        try:
            data = input.string("data")
            embedding = self.model.encode(data)
            return {"embedding": embedding.tolist()}
        except torch.cuda.OutOfMemoryError:
            torch.cuda.empty_cache()
            return self.error(ErrorCode.RESOURCE_EXHAUSTED, "GPU out of memory")
```

---

### 6. Hybrid Plugins and ARO Files

#### 6.1 The `aro-files` Provider Type

Plugins can include `.aro` feature set files alongside native code. These are parsed by the ARO compiler and registered as feature sets within the plugin's namespace.

```yaml
# plugin.yaml
name: plugin-auth
handle: Auth
provides:
  - type: swift-plugin
    path: Sources/
  - type: aro-files
    path: features/
```

The `aro-files` provider enables:
- **Event handlers**: Feature sets named `<EventName> Handler` become event handlers
- **Reusable feature sets**: Available via the `Invoke` action
- **Pure ARO plugins**: Plugins with only `aro-files` providers -- no native code, no compilation

#### 6.2 The `aro-templates` Provider Type

Plugins can also provide template files for the `Render` action:

```yaml
provides:
  - type: aro-templates
    path: templates/
```

Templates are embedded during `aro build` and available at runtime. The scaffolding CLI supports this:

```bash
aro new plugin --name my-templates --lang aro --templates
```

#### 6.3 Hybrid Loading Sequence

When a plugin has multiple providers, they load in order:
1. Native code (swift-plugin, rust-plugin, c-plugin, cpp-plugin) -- compiled and loaded first
2. ARO files (aro-files) -- parsed and registered after native code is available
3. Templates (aro-templates) -- registered in template registry

This ensures native actions are available when ARO feature sets reference them.

#### 6.4 Plugin Unload/Reload

The runtime supports unloading and reloading plugins at runtime via `UnifiedPluginLoader.shared.unload(pluginName:)` and `UnifiedPluginLoader.shared.reload(pluginName:)`. This is useful during development for hot-reloading plugin code without restarting the application. When a plugin is unloaded, all its actions, qualifiers, system objects, and event subscriptions are removed from their respective registries.

---

### 7. Plugin Scaffolding CLI

A new `aro new plugin` command generates a complete, ready-to-build plugin project.

#### 7.1 Syntax

```bash
# Interactive mode -- prompts for language, capabilities, name
aro new plugin

# Explicit mode
aro new plugin --name my-csv-processor --lang rust --actions --qualifiers

# Quick mode -- minimal defaults
aro new plugin my-greeting --lang swift

# Pure ARO plugin (no native code)
aro new plugin my-workflows --lang aro

# With templates
aro new plugin my-email-templates --lang aro --templates
```

#### 7.2 Supported Options

| Flag | Description | Default |
|------|-------------|---------|
| `--name` | Plugin name (kebab-case) | prompted |
| `--lang` | Language: `swift`, `rust`, `c`, `cpp`, `python`, `aro` | prompted |
| `--handle` | PascalCase namespace | derived from name |
| `--actions` | Include action scaffolding | yes |
| `--qualifiers` | Include qualifier scaffolding | no |
| `--services` | Include service scaffolding | no |
| `--system-objects` | Include system object scaffolding | no |
| `--events` | Include event handler scaffolding | no |
| `--templates` | Include aro-templates provider | no |
| `--hybrid` | Include both native code and aro-files | no |

#### 7.3 Generated Project Structure

**Swift:**
```
Plugins/my-greeting/
  plugin.yaml
  Package.swift          # depends on AROPluginSDK, type: .dynamic
  Sources/
    MyGreetingPlugin.swift    # @AROPlugin struct with example @Action
  Tests/
    MyGreetingTests.swift     # example test
```

**Rust:**
```
Plugins/my-csv-processor/
  plugin.yaml
  Cargo.toml             # depends on aro-plugin-sdk, cdylib, release profile
  src/
    lib.rs               # #[aro_plugin] mod with example #[action]
  tests/
    integration.rs       # example test
```

**C:**
```
Plugins/my-hash/
  plugin.yaml
  Makefile               # platform-aware, auto-detects OS
  include/
    aro_plugin_sdk.h     # the SDK header (copied in)
  src/
    plugin.c             # ARO_PLUGIN + ARO_ACTION macros with example
```

**C++:**
```
Plugins/my-audio/
  plugin.yaml
  Makefile               # C++ flags, -lstdc++
  include/
    aro_plugin_sdk.h     # C SDK header
    aro_plugin_sdk.hpp   # C++ wrapper header
  src/
    plugin.cpp           # ARO_PLUGIN + ARO_ACTION with C++ features
```

**Python:**
```
Plugins/my-stats/
  plugin.yaml
  src/
    plugin.py            # @plugin class with example @action
    requirements.txt     # includes aro-plugin-sdk
  tests/
    test_plugin.py       # example test
```

**Pure ARO:**
```
Plugins/my-workflows/
  plugin.yaml            # provides: aro-files only
  features/
    example.aro          # example feature set
```

---

### 8. `aro build` and Binary Embedding

When `aro build` compiles an ARO application to a native binary, plugins in `Plugins/` are embedded directly into the binary. This is necessary because the resulting binary must be **self-contained** -- it should run on any machine without requiring the `Plugins/` directory to be present alongside it.

The embedding process:
1. Each plugin's compiled library (`.dylib`/`.so`) is base64-encoded
2. The plugin's `plugin.yaml` is included alongside the encoded library
3. Both are stored as string constants in the LLVM IR module
4. At runtime startup, the binary extracts these to a temporary directory and loads them via `dlopen`

This means `aro build ./MyApp` produces a single binary that includes all plugin functionality. No separate plugin installation needed on the target machine.

---

### 9. Error Handling

#### 9.1 Standard Error Codes

All SDKs include the standard ARO error codes (0-10):

| Code | Name | Description |
|------|------|-------------|
| 0 | `SUCCESS` | Operation completed successfully |
| 1 | `INVALID_INPUT` | Missing or malformed input data |
| 2 | `NOT_FOUND` | Requested resource not found |
| 3 | `PERMISSION_DENIED` | Insufficient permissions |
| 4 | `TIMEOUT` | Operation timed out |
| 5 | `CONNECTION_FAILED` | Could not connect to external service |
| 6 | `EXECUTION_FAILED` | Internal processing error |
| 7 | `INVALID_STATE` | Plugin in wrong state for operation |
| 8 | `RESOURCE_EXHAUSTED` | Memory, disk, or GPU resources exhausted |
| 9 | `UNSUPPORTED` | Operation not supported |
| 10 | `RATE_LIMITED` | Too many requests |

#### 9.2 Domain-Specific Error Categories

Plugins can use domain-specific error codes following the naming convention `{CATEGORY}_{SPECIFIC_ERROR}`:

| Category | Examples |
|----------|----------|
| `VALIDATION` | `VALIDATION_MISSING_FIELD`, `VALIDATION_INVALID_FORMAT`, `VALIDATION_OUT_OF_RANGE` |
| `IO` | `IO_FILE_NOT_FOUND`, `IO_PERMISSION_DENIED`, `IO_DISK_FULL` |
| `AUTH` | `AUTH_INVALID_TOKEN`, `AUTH_EXPIRED`, `AUTH_INSUFFICIENT_SCOPE` |
| `RATE_LIMIT` | `RATE_LIMIT_EXCEEDED`, `RATE_LIMIT_QUOTA_EXHAUSTED` |

#### 9.3 Error Message Convention

Plugin error messages are appended to the ARO statement context by the runtime:

```
Cannot Hash the <digest> from the <input>.
Plugin error [INVALID_INPUT]: Unsupported algorithm 'sha999'
```

Error messages should be concise and specific -- they are shown directly to the user.

---

### 10. Manifest Additions

#### 10.1 Platform-Specific Configuration

Plugins can declare platform requirements:

```yaml
platforms:
  macos:
    min-version: "12.0"
    architectures: [arm64, x86_64]
  linux:
    distributions: [ubuntu, debian]
    min-version: "20.04"
```

Platform-specific build overrides within providers:

```yaml
provides:
  - type: c-plugin
    path: src/
    build:
      compiler: clang
      flags: [-O2, -fPIC, -shared]
    platforms:
      linux:
        build:
          flags: [-O2, -fPIC, -shared, -lpthread]
```

#### 10.2 System Requirements

The `requirements.system` field documents system library dependencies:

```yaml
requirements:
  system:
    - name: ffmpeg
      install:
        macos: "brew install ffmpeg"
        ubuntu: "apt-get install ffmpeg libavcodec-dev libavformat-dev"
        windows: "choco install ffmpeg"
    - name: libssl
      install:
        macos: "brew install openssl"
        ubuntu: "apt-get install libssl-dev"
```

The runtime checks for these at install time and prints install commands if missing.

#### 10.3 Deprecation Strategy

Plugins can declare deprecated features in `aro_plugin_info`:

```json
{
  "deprecations": [
    {
      "feature": "action:OldHash",
      "message": "Use ComputeHash instead. OldHash will be removed in 2.0.0",
      "since": "1.2.0",
      "remove_in": "2.0.0"
    }
  ]
}
```

The runtime emits warnings when deprecated features are used. The `aro check` command also reports deprecation warnings.

---

### 11. Performance

#### 11.1 Optimization Techniques

The SDKs and documentation recommend:

- **Compile-time regex**: Use `once_cell` / `lazy_static` (Rust) or `static let` (Swift) for compiled regex patterns instead of recompiling per call
- **Zero-copy string handling**: Use `std::string_view` (C++), `&str` (Rust), or `Substring` (Swift) to avoid copying input data
- **SIMD**: Use platform SIMD intrinsics for batch numerical operations (e.g., `memchr` crate in Rust)
- **Profile-guided optimization (PGO)**: For performance-critical plugins, use PGO with representative workloads

#### 11.2 Rust Release Profile

The scaffolding generates an optimized release profile:

```toml
[profile.release]
lto = true           # link-time optimization
codegen-units = 1    # better optimization at cost of compile time
panic = "abort"      # no unwinding across FFI
opt-level = "z"      # optimize for size (or "3" for speed)
```

#### 11.3 Python GPU Acceleration

For ML plugins, the SDK documents:
- CUDA detection: `torch.cuda.is_available()`
- Model quantization: `BitsAndBytesConfig(load_in_4bit=True)` for memory-constrained GPUs
- OOM handling: `torch.cuda.empty_cache()` in error recovery
- Lazy imports: Import heavy dependencies (`transformers`, `torch`) only when first needed
- Model caching: Load models in `on_init()`, reuse across calls

---

### 12. Testing Support

Each SDK includes testing utilities so plugin authors can test without loading through the ARO runtime.

#### 12.1 Unit Testing (Per-Language)

**Swift:**
```swift
import Testing
import AROPluginSDK

@Test func greetReturnsMessage() {
    let plugin = GreetingPlugin()
    let input = ActionInput(["name": "Alice"])
    let output = plugin.greet(input: input)
    #expect(output.isSuccess)
    #expect(output["greeting"] == "Hello, Alice!")
}
```

**Rust:**
```rust
#[cfg(test)]
mod tests {
    use super::csv_plugin;
    use aro_plugin_sdk::testing::*;

    #[test]
    fn parse_csv_basic() {
        let input = mock_input(json!({"data": "a,b,c\n1,2,3"}));
        let output = csv_plugin::parse_csv(&input).unwrap();
        assert_eq!(output.get("count"), Some(&json!(2)));
    }
}
```

**C:**
```c
#include "aro_plugin_sdk.h"
#include <assert.h>

void test_compute_hash() {
    aro_test_ctx* ctx = aro_test_begin();
    aro_test_set_string(ctx, "data", "hello");
    const char* result = action_ComputeHash(ctx);
    assert(aro_test_output_int(ctx, "hash") != 0);
    aro_test_end(ctx);
}
```

**Python:**
```python
import pytest
from aro_plugin_sdk.testing import mock_input
from plugin import StatsPlugin

def test_average_qualifier():
    plugin = StatsPlugin()
    result = plugin.average([10, 20, 30])
    assert result == 20.0
```

#### 12.2 Component Testing with ARO Files

Plugins should also include `.aro` test files that test the plugin through the ARO runtime:

```aro
(* tests/hash-tests.aro *)
(Application-Start: Hash Tests) {
    (* Test 1: Hash produces consistent results *)
    Hash the <hash1: sha256> from "hello".
    Hash the <hash2: sha256> from "hello".
    Compare the <hash1> against the <hash2>.
    When <comparison: not-equal> {
        Log "FAIL: Hash not deterministic" to the <console>.
        Return an <Error: status> for the <test>.
    }
    Log "PASS: Hash deterministic" to the <console>.
    Return an <OK: status> for the <tests>.
}
```

Run with: `aro run ./tests/hash-tests.aro`

This catches issues that unit tests miss: JSON serialization bugs, registration errors, qualifier resolution failures.

#### 12.3 Memory Safety Testing

For C/C++/Rust plugins, the documentation recommends AddressSanitizer:

```bash
# C/C++: compile with sanitizer
clang -fsanitize=address -shared -fPIC -o libplugin.dylib src/plugin.c

# Run tests through ARO
aro run ./tests/plugin-tests.aro

# Linux: Valgrind
valgrind --leak-check=full aro run ./tests/plugin-tests.aro
```

---

### 13. CLI Commands

The following CLI commands support the plugin development workflow:

| Command | Description |
|---------|-------------|
| `aro new plugin` | Scaffold a new plugin project |
| `aro plugins list` | List installed plugins (name, version, source, provides) |
| `aro plugins list --verbose` | Detailed plugin information |
| `aro plugins validate` | Check manifests, dependencies, handle conflicts |
| `aro plugins rebuild` | Recompile all native plugins |
| `aro plugins export` | Write plugin sources to `.aro-sources` for reproducibility |
| `aro plugins restore` | Re-install all plugins from `.aro-sources` |
| `aro plugins docs <name>` | Generate documentation from plugin metadata |
| `aro actions list` | List all registered actions (built-in + plugin) with source |
| `aro check` | Validate manifest, check for deprecations, verify dependencies |

---

### 14. Plugin Documentation Generation

The SDK metadata enables automatic documentation generation:

```bash
aro plugins docs my-plugin          # Generate markdown docs
aro plugins docs my-plugin --html   # Generate HTML docs
```

Generated from `aro_plugin_info` metadata + source code docstrings. Includes: action list with verbs/role/prepositions, qualifier list with input types and parameter documentation, system objects with capabilities, event subscriptions and emissions.

---

## Implementation Plan

### Phase 1: Clean ABI and Runtime Changes

1. Replace the three ABIs with the unified contract
2. Remove `AROService` protocol and `ServiceRegistry` (route through `aro_plugin_execute`)
3. Remove old `aro_plugin_init` service-discovery pattern and 3-parameter `_call` signature
4. Add `aro_plugin_init()` / `aro_plugin_shutdown()` lifecycle hooks
5. Add `aro_plugin_on_event` support to `NativePluginHost` and `PythonPluginHost`
6. Add `_events` response parsing to plugin action wrappers
7. Add system object function support (`aro_object_read/write/list`)
8. Add `aro_plugin_invoke` callback mechanism
9. Register built-in qualifiers in `QualifierRegistry` (single source of truth)
10. Add parameterized qualifier support (`_with` in qualifier input JSON)
11. Add qualifier chaining (pipe syntax in parser, sequential resolution in registry)
12. Add qualifier conflict detection at load time
13. Pass full descriptors and `_context` in plugin input JSON
14. Rewrite all example plugins to use the new ABI
15. Update the Plugin Guide book

### Phase 2: Python SDK + Persistent Mode

1. Build the `aro-plugin-sdk` Python package with decorators and helpers
2. Implement persistent subprocess mode in `PythonPluginHost`
3. Add `aro new plugin --lang python` scaffolding
4. Port `QualifierPluginPython` and `MarkdownRenderer` examples to use the SDK
5. Add testing utilities
6. Document GPU acceleration patterns

### Phase 3: C/C++ SDK (Header-Only)

1. Build `aro_plugin_sdk.h` single-header library with JSON parser and arena allocator
2. Build `aro_plugin_sdk.hpp` C++ wrapper with RAII, exception safety, templates
3. Implement all macros: `ARO_PLUGIN`, `ARO_ACTION`, `ARO_QUALIFIER`, `ARO_SYSTEM_OBJECT`, etc.
4. Add `aro new plugin --lang c` and `--lang cpp` scaffolding
5. Port `HashPluginDemo`, `QualifierPluginC` examples to use the SDK
6. Add testing utilities

### Phase 4: Rust SDK (Proc Macro Crate)

1. Build `aro-plugin-sdk` crate with proc macros and FFI helpers
2. Implement `#[aro_plugin]`, `#[action]`, `#[qualifier]`, `#[system_object]` macros
3. Add `aro new plugin --lang rust` scaffolding
4. Port `CSVProcessor` example to use the SDK
5. Add testing utilities

### Phase 5: Swift SDK (Swift Macros)

1. Build `AROPluginSDK` Swift package with macros and helpers
2. Implement `@AROPlugin`, `@Action`, `@Qualifier`, `@Service`, `@SystemObject`, `@OnEvent`, `@OnInit`, `@OnShutdown` macros
3. Add `aro new plugin --lang swift` scaffolding
4. Port `GreetingPlugin`, `QualifierPlugin`, `SQLiteExample`, `ZipService` to use the SDK
5. Add testing utilities

### Phase 6: Documentation & Polish

1. Add `aro plugins docs` command
2. Update all examples in the repository
3. Update CLAUDE.md, OVERVIEW.md, and website
4. Update the Plugin Guide book (all chapters)
5. Add `aro new plugin --lang aro` for pure ARO plugins and templates

---

## Design Decisions

### Why replace the old ABI instead of versioning it?

ARO is pre-1.0. Clean code is more valuable than backward compatibility at this stage. One good way is better than many legacy paths. The old service ABI (`_call` with out-pointers and error codes) adds complexity to the runtime without providing functionality that the unified ABI cannot achieve.

### Why macros/decorators instead of code generation?

1. It creates generated files that must be kept in sync with the source
2. It adds a build step before the language's native build
3. Macros/decorators are idiomatic in each language and compose naturally
4. The generated code is invisible -- reducing cognitive overhead

### Why a single-header C/C++ SDK instead of a static library?

1. No build system dependency -- works with any C/C++ compiler
2. Trivially vendorable (just copy the file)
3. Precedent: stb libraries, SQLite amalgamation, miniz
4. The JSON parser and arena allocator are small (~500 lines total)

### Why persistent mode for Python instead of embedding?

1. Embedding CPython is complex and creates version conflicts
2. Subprocess isolation prevents plugin crashes from taking down the runtime
3. The stdin/stdout JSON-line protocol is debuggable and language-agnostic
4. Persistent mode eliminates the startup overhead of per-call subprocesses

### Why deprecate AROService / ServiceRegistry?

The `AROService` protocol (`init()`, `call()`, `shutdown()`) is an older pattern that duplicates functionality now covered by the unified plugin ABI:
- `init()` -> `aro_plugin_init()`
- `call()` -> `aro_plugin_execute("service:<method>", ...)`
- `shutdown()` -> `aro_plugin_shutdown()`

One clean path is better than two overlapping mechanisms. All existing service-based plugins (SQLiteExample, ZipService) will be rewritten to use the new pattern.

### Why add qualifier chaining?

Sequential `Compute` statements work but are verbose for simple transformation pipelines. Qualifier chaining with `|` enables:
```aro
Compute the <result: stats.sort | list.take> from the <data> with { count: 5 }.
```
Instead of:
```aro
Compute the <sorted: stats.sort> from the <data>.
Compute the <result: list.take> from the <sorted> with { count: 5 }.
```

---

## Appendix A: SDK Comparison Matrix

```
+---------------------+---------+--------+--------+--------+--------+
| Feature             | Swift   | Rust   | C      | C++    | Python |
+---------------------+---------+--------+--------+--------+--------+
| Distribution        | SPM pkg | Crate  | Header | Header | pip    |
| Actions             |  yes    |  yes   |  yes   |  yes   |  yes   |
| Qualifiers          |  yes    |  yes   |  yes   |  yes   |  yes   |
| Parameterized quals |  yes    |  yes   |  yes   |  yes   |  yes   |
| Services            |  yes    |  yes   |  yes   |  yes   |  yes   |
| System objects      |  yes    |  yes   |  yes   |  yes   |  yes   |
| Event subscribe     |  yes    |  yes   |  yes   |  yes   |  yes   |
| Event emit          |  yes    |  yes   |  yes   |  yes   |  yes   |
| Invoke (callback)   |  yes    |  yes   |  yes   |  yes   |  yes   |
| Lifecycle hooks     |  yes    |  yes   |  yes   |  yes   |  yes   |
| Persistent state    |  yes    |  yes   |  yes   |  yes   |  yes   |
| Async support       |  yes    |  no*   |  no    |  no    |  yes** |
| Testing helpers     |  yes    |  yes   |  yes   |  yes   |  yes   |
| Standard errors     |  yes    |  yes   |  yes   |  yes   |  yes   |
| Descriptor access   |  yes    |  yes   |  yes   |  yes   |  yes   |
| Context access      |  yes    |  yes   |  yes   |  yes   |  yes   |
| Code generation     | Macros  | Proc   | C      | C      | Deco-  |
|                     |         | macros | macros | macros | rators |
| JSON handling       | Hidden  | Hidden | Hidden | Hidden | Hidden |
| Memory management   | Hidden  | Hidden | Hidden | Hidden | N/A    |
| unsafe/cdecl        | Hidden  | Hidden | Hidden | Hidden | N/A    |
| Exception safety    | N/A     | panic  | N/A    | catch  | N/A    |
|                     |         | =abort |        | at FFI |        |
+---------------------+---------+--------+--------+--------+--------+

*  Rust async support via tokio integration is a future consideration
** Python persistent mode inherently supports async via event loop
```

## Appendix B: Ceremony Reduction Estimates

```
+--------------------+----------+---------+----------+-----------+
| Plugin Type        | Language | Before  | After    | Reduction |
+--------------------+----------+---------+----------+-----------+
| Qualifier-only     | C        | ~95%    | ~20%     | -75pp     |
| Action-only        | Swift    | ~80%    | ~15%     | -65pp     |
| Action-only        | C        | ~70%    | ~25%     | -45pp     |
| Action-only        | C++      | ~65%    | ~20%     | -45pp     |
| Service            | Swift    | ~55%    | ~15%     | -40pp     |
| Action-only        | Rust     | ~35%    | ~10%     | -25pp     |
| Action/qualifier   | Python   | ~20%    | ~10%     | -10pp     |
+--------------------+----------+---------+----------+-----------+
```

## Appendix C: Affected Code and Books

The following must be updated when this proposal is implemented:

**Runtime code to modify:**
- `Sources/ARORuntime/Plugins/UnifiedPluginLoader.swift` -- new ABI loading
- `Sources/ARORuntime/Plugins/NativePluginHost.swift` -- lifecycle hooks, system objects, invoke callback
- `Sources/ARORuntime/Plugins/PythonPluginHost.swift` -- persistent mode, lifecycle hooks
- `Sources/ARORuntime/Services/PluginLoader.swift` -- remove legacy service ABI
- `Sources/ARORuntime/Actions/ActionRegistry.swift` -- qualifier chaining support
- `Sources/ARORuntime/Qualifiers/QualifierRegistry.swift` -- built-in registration, parameters, conflicts
- `Sources/AROParser/Parser.swift` -- pipe syntax for qualifier chaining

**Runtime code to remove:**
- `AROService` protocol and `ServiceRegistry` (replaced by unified plugin ABI)
- `aro_plugin_init` service-discovery code path
- 3-parameter `_call` function loading in `NativePluginHost`

**Examples to rewrite:**
- `Examples/GreetingPlugin/` -- Swift SDK
- `Examples/HashPluginDemo/` -- C SDK
- `Examples/CSVProcessor/` -- Rust SDK
- `Examples/MarkdownRenderer/` -- Python SDK
- `Examples/SQLiteExample/` -- Swift SDK (service pattern -> action pattern)
- `Examples/ZipService/` -- Swift SDK (service pattern -> action pattern)
- `Examples/QualifierPlugin/` -- Swift SDK
- `Examples/QualifierPluginC/` -- C SDK
- `Examples/QualifierPluginPython/` -- Python SDK

**Book chapters to update:**
- `Book/ThePluginGuide/` -- All chapters reflecting new ABI, SDK usage, removed service pattern
- `Book/TheLanguageGuide/Chapter24-CustomActions.md`
- `Book/TheLanguageGuide/Chapter25-CustomServices.md` -- rewrite for unified approach
- `Book/TheLanguageGuide/Chapter26-Plugins.md`
