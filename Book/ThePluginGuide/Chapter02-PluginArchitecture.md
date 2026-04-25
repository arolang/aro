# Chapter 2: Plugin Architecture

*"Any sufficiently advanced abstraction is indistinguishable from magic—until you need to debug it."*

---

Before writing plugins, you need to understand how they work. This chapter reveals the machinery behind ARO's plugin system: how plugins are discovered, loaded, and invoked; how data flows between ARO and plugin code; and how memory is managed across language boundaries.

This knowledge will make you a better plugin author. When something goes wrong—and something always goes wrong—you'll know where to look.

## 2.1 The Big Picture

When an ARO application starts, a sequence of events unfolds:

1. **Discovery**: ARO scans the `Plugins/` directory for `plugin.yaml` manifests
2. **Dependency Resolution**: Plugins are sorted topologically based on their dependencies
3. **Loading**: Each plugin's compiled library is loaded into memory
4. **Info**: ARO calls `aro_plugin_info()` to read the plugin's metadata (required)
5. **Initialization**: ARO calls `aro_plugin_init()` for one-time setup (optional)
6. **Registration**: Actions, qualifiers, services, and system objects are registered in the runtime
7. **Execution**: When ARO code invokes a plugin action or service, `aro_plugin_execute()` is called
8. **Shutdown**: ARO calls `aro_plugin_shutdown()` for cleanup (optional)

Let's examine each stage.

## 2.2 Plugin Discovery

ARO looks for plugins in a specific location relative to your application:

```
MyApp/
├── main.aro
├── aro.yaml
└── Plugins/              ← ARO scans here
    ├── plugin-hash/
    │   ├── plugin.yaml   ← Required manifest
    │   └── libhash.dylib
    └── plugin-csv/
        ├── plugin.yaml
        └── target/release/libcsv.dylib
```

The `Plugins/` directory (capitalized) is the primary location. Each subdirectory represents one plugin and must contain a `plugin.yaml` manifest.

The discovery process is straightforward:

```
For each subdirectory in Plugins/:
    If plugin.yaml exists:
        Parse the manifest
        Validate required fields
        Add to discovered plugins list
    Else:
        Log warning and skip
```

## 2.3 The plugin.yaml Manifest

The manifest is the contract between your plugin and ARO. Here's a complete example:

```yaml
name: plugin-example
version: 1.0.0
description: "An example plugin demonstrating the manifest format"
author: "Your Name"
license: MIT
aro-version: ">=0.1.0"

source:
  git: "https://github.com/you/plugin-example"
  ref: "main"
  commit: "abc123..."

provides:
  - type: c-plugin
    path: src/
    build:
      compiler: clang
      flags: ["-O2", "-fPIC", "-shared"]
      output: libexample.dylib

dependencies:
  other-plugin:
    git: "https://github.com/other/plugin"
    ref: "v1.0.0"
```

Key fields:

- **name**: Unique identifier, lowercase with hyphens
- **version**: Semantic version (major.minor.patch)
- **provides**: List of components the plugin provides
- **dependencies**: Other plugins this one requires

The `provides` section tells ARO what type of plugin this is and how to build it. We'll cover the details in Chapter 4.

## 2.4 Dependency Resolution

Plugins can depend on other plugins. ARO resolves these dependencies using topological sorting—ensuring that if Plugin A depends on Plugin B, Plugin B is loaded first.

```
plugin-app
    └── depends on: plugin-database
                        └── depends on: plugin-core
```

Loading order: `plugin-core` → `plugin-database` → `plugin-app`

Circular dependencies are detected and reported as errors:

```
Error: Circular dependency detected:
  plugin-a → plugin-b → plugin-c → plugin-a
```

If you encounter this, you'll need to restructure your plugins to break the cycle.

## 2.5 The C ABI Bridge

Here's where it gets interesting. ARO is written in Swift. Plugins can be written in C, C++, Rust, Swift, or Python. How do they communicate?

The answer is the **C Application Binary Interface (ABI)**—a standard way for compiled code to call functions across language boundaries.

All native plugins must expose functions using C calling conventions. The full interface is:

```c
/* REQUIRED — return plugin metadata as JSON */
char* aro_plugin_info(void);

/* OPTIONAL — one-time setup (no return value) */
void aro_plugin_init(void);

/* OPTIONAL — one-time cleanup (no return value) */
void aro_plugin_shutdown(void);

/* OPTIONAL — execute an action or service method, return JSON result */
char* aro_plugin_execute(const char* action, const char* input_json);

/* OPTIONAL — execute a qualifier transformation, return JSON result */
char* aro_plugin_qualifier(const char* qualifier, const char* input_json);

/* OPTIONAL — called when a subscribed event fires */
void aro_plugin_on_event(const char* event_type, const char* data_json);

/* OPTIONAL — system object read/write/list */
char* aro_object_read(const char* object_id, const char* key);
int32_t aro_object_write(const char* object_id, const char* key, const char* value_json);
char* aro_object_list(const char* object_id);

/* REQUIRED if plugin allocates strings — free memory allocated by plugin */
void aro_plugin_free(char* ptr);
```

`aro_plugin_info` is the **primary interface function** and is always required. Every other function is called only if declared in the metadata that `aro_plugin_info` returns.

In Swift, use `@_cdecl`:

```swift
@_cdecl("aro_plugin_info")
public func pluginInfo() -> UnsafeMutablePointer<CChar> {
    // Return plugin metadata as JSON
}

@_cdecl("aro_plugin_execute")
public func pluginExecute(
    _ actionPtr: UnsafePointer<CChar>,
    _ inputPtr: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
    // Execute action and return JSON result
}
```

In Rust, use `#[no_mangle]` and `extern "C"`:

```rust
#[no_mangle]
pub extern "C" fn aro_plugin_info() -> *mut c_char {
    // Return plugin metadata as JSON
}

#[no_mangle]
pub extern "C" fn aro_plugin_execute(
    action: *const c_char,
    input_json: *const c_char,
) -> *mut c_char {
    // Execute action and return JSON result
}
```

In C and C++, it's natural—C is the lingua franca:

```c
char* aro_plugin_info(void) {
    // Return plugin metadata as JSON
}

char* aro_plugin_execute(const char* action, const char* input_json) {
    // Execute action and return JSON result
}
```

The C ABI ensures that regardless of what language the plugin is written in, ARO can call its functions using the same mechanism.

## 2.6 Plugin Info and Initialization

### aro_plugin_info — Required

When ARO loads a plugin library, it immediately calls `aro_plugin_info`. This is the **required** primary interface function that returns a JSON string describing everything the plugin provides:

```json
{
  "name": "plugin-hash",
  "version": "1.0.0",
  "actions": ["Hash"],
  "qualifiers": [
    { "name": "djb2",  "accepts_parameters": false },
    { "name": "fnv1a", "accepts_parameters": false },
    { "name": "md5",   "accepts_parameters": false }
  ],
  "services": [
    {
      "name": "hash",
      "methods": ["djb2", "fnv1a", "md5"]
    }
  ],
  "system_objects": ["hash-cache"],
  "events": {
    "subscribes": ["AppStart"],
    "emits":      ["HashComputed"]
  },
  "deprecations": [
    { "name": "crc32", "reason": "Use md5 instead", "removed_in": "2.0.0" }
  ]
}
```

Top-level fields:

- **name**: Plugin identifier (must match `plugin.yaml`)
- **version**: Semantic version
- **actions**: Verb names routed through `aro_plugin_execute("Hash", ...)`
- **qualifiers**: Qualifier names routed through `aro_plugin_qualifier(name, ...)`. Each entry may declare `accepts_parameters: true` if the qualifier accepts inline arguments.
- **services**: Named services with their methods, also routed through `aro_plugin_execute("service:<name>.<method>", ...)`
- **system_objects**: System object IDs that this plugin manages via `aro_object_read/write/list`
- **events.subscribes**: Event types the plugin wants to receive via `aro_plugin_on_event`
- **events.emits**: Event types this plugin may emit (informational, for tooling)
- **deprecations**: Identifiers scheduled for removal

ARO parses this metadata at load time and registers each capability in the appropriate runtime registry.

### aro_plugin_init — Optional

After reading the info, ARO calls `aro_plugin_init()` if it is present. Use this for one-time setup—opening database connections, pre-loading lookup tables, seeding RNG state—that should happen once per process lifetime:

```c
void aro_plugin_init(void) {
    // One-time setup: no return value, no service metadata
    cache_init();
    open_connection_pool();
}
```

This function takes no arguments and returns nothing. It is called exactly once, after all plugins have been loaded but before any ARO feature sets execute.

### aro_plugin_shutdown — Optional

The counterpart to `aro_plugin_init`. ARO calls this during graceful shutdown so the plugin can release resources:

```c
void aro_plugin_shutdown(void) {
    close_connection_pool();
    cache_flush();
}
```

## 2.7 The Execute Function

All actions and service calls flow through a single `aro_plugin_execute` function. The first argument is a **dispatch key** that tells the plugin what to do; the second argument is a JSON payload:

```c
char* aro_plugin_execute(const char* action, const char* input_json);
```

The dispatch key follows these conventions:

| Caller intent | Dispatch key format | Example |
|---------------|---------------------|---------|
| Plugin action | Verb name | `"Hash"` |
| Service method | `service:<name>.<method>` | `"service:hash.md5"` |

For example, to invoke the `md5` method of the `hash` service:

```c
// ARO calls:
aro_plugin_execute("service:hash.md5", "{\"data\":\"hello world\"}")
```

The function returns a newly allocated JSON string. On success it contains the result; on error it contains an `"error"` field (see Section 2.13). ARO calls `aro_plugin_free` on the returned pointer when it is done.

A minimal C implementation:

```c
char* aro_plugin_execute(const char* action, const char* input_json) {
    if (strcmp(action, "service:hash.md5") == 0) {
        // Parse input, compute hash...
        return strdup("{\"hash\": \"5eb63bbbe01eeed093cb22bb8f5acdc3\"}");
    }
    if (strcmp(action, "Hash") == 0) {
        // Handle Hash action...
        return strdup("{\"result\": \"...\"}");
    }
    return strdup("{\"error\": \"Unknown action\"}");
}
```

In Swift:

```swift
@_cdecl("aro_plugin_execute")
public func pluginExecute(
    _ actionPtr: UnsafePointer<CChar>,
    _ inputPtr: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
    let action   = String(cString: actionPtr)
    let inputJSON = String(cString: inputPtr)

    let result: String
    switch action {
    case "service:hash.md5":
        result = computeMD5(inputJSON)
    case "Hash":
        result = handleHashAction(inputJSON)
    default:
        result = "{\"error\": \"Unknown action: \(action)\"}"
    }

    return strdup(result)
}
```

The function always returns a pointer; it never returns `NULL`. Error details are embedded in the JSON payload rather than signalled through a return code.

## 2.8 Event Subscriptions

Plugins can subscribe to runtime events by declaring them in `aro_plugin_info`:

```json
"events": {
    "subscribes": ["AppStart", "UserCreated"],
    "emits":      ["HashComputed"]
}
```

For each subscribed event type, ARO calls `aro_plugin_on_event` when that event fires:

```c
void aro_plugin_on_event(const char* event_type, const char* data_json);
```

A typical implementation:

```c
void aro_plugin_on_event(const char* event_type, const char* data_json) {
    if (strcmp(event_type, "AppStart") == 0) {
        warm_up_cache(data_json);
    } else if (strcmp(event_type, "UserCreated") == 0) {
        invalidate_user_cache(data_json);
    }
}
```

This function returns nothing. It is called asynchronously; do not block for long periods inside it.

## 2.9 System Objects

Plugins that manage stateful resources—counters, caches, connection pools—can expose them as **system objects**. System objects are accessed from ARO code using the standard `<object-id: key>` qualifier syntax.

Declare system object IDs in `aro_plugin_info`:

```json
"system_objects": ["hash-cache"]
```

Then implement the three access functions:

```c
/* Read a key from the object; return JSON value or null */
char* aro_object_read(const char* object_id, const char* key) {
    if (strcmp(object_id, "hash-cache") == 0) {
        const char* value = cache_get(key);
        return value ? strdup(value) : strdup("null");
    }
    return strdup("null");
}

/* Write a key into the object; return 0 on success */
int32_t aro_object_write(const char* object_id, const char* key,
                         const char* value_json) {
    if (strcmp(object_id, "hash-cache") == 0) {
        cache_set(key, value_json);
        return 0;
    }
    return 1;
}

/* List all keys in the object; return JSON array */
char* aro_object_list(const char* object_id) {
    if (strcmp(object_id, "hash-cache") == 0) {
        return cache_list_keys_as_json();
    }
    return strdup("[]");
}
```

ARO calls `aro_plugin_free` on any pointer returned by these functions.

## 2.10 JSON-Based Communication

All data exchange between ARO and plugins uses JSON. This might seem inefficient, but the benefits are substantial:

**Language Agnosticism**: Every language can parse JSON. There's no need for complex serialization protocols or generated code.

**Debugging Simplicity**: You can log the JSON being passed and see exactly what's happening. No binary inspection required.

**Schema Flexibility**: Plugins can evolve their interfaces without breaking binary compatibility. New fields can be added; old fields can be deprecated gracefully.

**Human Readability**: When something goes wrong, the error messages make sense.

Input to a hash service might look like:

```json
{
  "data": "hello world",
  "encoding": "utf8"
}
```

Output might be:

```json
{
  "hash": "5eb63bbbe01eeed093cb22bb8f5acdc3",
  "algorithm": "md5",
  "elapsed_ms": 0.042
}
```

For performance-critical plugins, the JSON overhead is usually negligible compared to the actual computation. If serialization becomes a bottleneck, consider batching multiple operations into a single call.

## 2.11 Memory Management

Memory management across the C ABI requires careful attention. The basic rule:

**The allocator frees.**

If ARO allocates memory and passes it to your plugin, ARO will free it. If your plugin allocates memory and returns it to ARO, your plugin must provide `aro_plugin_free` so ARO can release it.

The standard pattern uses `strdup()` for allocating result strings:

```c
char* aro_plugin_execute(const char* action, const char* input_json) {
    // Plugin allocates with strdup()
    return strdup("{\"status\": \"ok\"}");
    // ARO will call aro_plugin_free() on this pointer when done
}

void aro_plugin_free(char* ptr) {
    free(ptr);
}
```

`aro_plugin_free` is called by ARO on every pointer returned from:

- `aro_plugin_info`
- `aro_plugin_execute`
- `aro_plugin_qualifier`
- `aro_object_read`
- `aro_object_list`

Strings passed **into** your plugin (the `action`, `input_json`, `event_type`, `data_json`, `key`, and `value_json` parameters) are owned by ARO. Never free them.

Memory leaks in plugins are insidious—they affect the entire ARO runtime. Use tools like Valgrind (Linux) or Instruments (macOS) to verify your plugin doesn't leak.

## 2.12 Python Plugins: A Different Path

Python plugins follow the same conceptual model but use a different transport mechanism.

Instead of loading a dynamic library, ARO spawns a Python subprocess. Communication happens through standard input/output with JSON messages:

```
ARO → Python subprocess:
{"action": "analyze", "input": {"text": "hello world"}}

Python subprocess → ARO:
{"result": {"word_count": 2, "char_count": 11}}
```

The Python plugin must define functions following a naming convention:

```python
def aro_plugin_info():
    return {
        "name": "text-analyzer",
        "version": "1.0.0",
        "actions": ["analyze", "summarize"]
    }

def aro_action_analyze(input_json):
    import json
    data = json.loads(input_json)
    # Process...
    return json.dumps(result)
```

The subprocess overhead (~50-100ms per call) makes Python plugins unsuitable for high-frequency operations. But for tasks like ML inference where the computation itself takes seconds, the overhead is negligible.

## 2.13 The UnifiedPluginLoader

ARO uses a `UnifiedPluginLoader` that delegates to specialized hosts based on plugin type:

```
UnifiedPluginLoader
    ├── NativePluginHost    → C, C++, Rust plugins
    ├── SwiftPluginHost     → Swift plugins
    ├── PythonPluginHost    → Python plugins
    └── AROFilePlugin       → ARO feature set plugins
```

Each host knows how to:

1. Locate the plugin's compiled artifacts
2. Load them into memory or spawn processes
3. Call `aro_plugin_info` to read metadata
4. Call `aro_plugin_init` for one-time setup (if present)
5. Register actions, qualifiers, services, system objects, and event subscriptions with ARO's runtime
6. Call `aro_plugin_shutdown` during teardown (if present)

This abstraction means you don't need to worry about the loading mechanics—just follow the conventions for your plugin type, and ARO handles the rest.

## 2.14 Thread Safety

ARO applications can be highly concurrent. HTTP servers handle multiple requests simultaneously. Event handlers fire in parallel.

Your plugin code must be thread-safe.

For stateless plugins (most of them), this is automatic—each call operates on its own data.

For stateful plugins, you need synchronization:

```swift
private let lock = NSLock()
private var state: [String: Int] = [:]

func processCall(...) {
    lock.lock()
    defer { lock.unlock() }

    // Access shared state safely
}
```

Or in Rust, use `Mutex` or atomic operations:

```rust
use std::sync::Mutex;

lazy_static! {
    static ref STATE: Mutex<HashMap<String, i32>> = Mutex::new(HashMap::new());
}
```

Race conditions in plugins can cause subtle, hard-to-reproduce bugs. When in doubt, add synchronization.

## 2.15 Error Handling

Errors in plugins are reported by returning a JSON object containing an `"error"` key from `aro_plugin_execute` or `aro_plugin_qualifier`:

```c
char* aro_plugin_execute(const char* action, const char* input_json) {
    if (invalid_input) {
        return strdup("{\"error\": \"Invalid input: expected string\"}");
    }
    // ...
}
```

ARO will propagate these errors to the calling ARO code, where they can be handled normally:

```aro
Call the <result> from the <my-plugin: operation> with <data>.

(* If the plugin returns an error, execution stops here *)
(* and the error becomes the feature set's result *)
```

Include enough context in error messages to diagnose problems:

```json
{
  "error": "Failed to parse CSV",
  "details": "Unexpected quote at line 42, column 15",
  "input_preview": "...malformed,\"data..."
}
```

## 2.16 Putting It All Together

### Startup trace

When an ARO application with `plugin-hash` starts:

1. **Discovery**: ARO finds `Plugins/plugin-hash/plugin.yaml`
2. **Loading**: `libhash.dylib` is loaded into memory via `dlopen`
3. **Info**: ARO calls `aro_plugin_info()` → receives JSON declaring actions, qualifiers, services, and system objects
4. **Init**: ARO calls `aro_plugin_init()` if present → plugin warms up its cache
5. **Registration**: `Hash` action, `djb2`/`fnv1a`/`md5` qualifiers, `hash` service, and `hash-cache` system object are registered in their respective runtime registries
6. **Event subscription**: ARO subscribes the plugin to `AppStart` events (as declared in `events.subscribes`)

### Execution trace

When ARO executes `Call the <hash> from the <plugin-hash: djb2> with { data: "hello" }.`:

1. **Action lookup**: ARO finds the `hash` service in the registry under `plugin-hash`
2. **Method resolution**: `djb2` is a known method of the `hash` service
3. **Argument serialization**: `{ data: "hello" }` becomes `{"data":"hello"}`
4. **Dispatch**: ARO calls `aro_plugin_execute("service:hash.djb2", "{\"data\":\"hello\"}")`
5. **Plugin processing**: Your code parses JSON, computes the hash, builds the result string
6. **Result return**: Plugin returns `"{\"hash\":\"5d41402abc4b2a76\"}"` (a `strdup`-allocated pointer)
7. **Memory cleanup**: ARO calls `aro_plugin_free` on the returned pointer after parsing
8. **Result parsing**: ARO parses the JSON result
9. **Binding**: The result is bound to `<hash>` in ARO's symbol table
10. **Continuation**: ARO continues with the next statement

### Shutdown trace

When the ARO application receives SIGINT or SIGTERM:

1. **Event emission**: ARO fires `AppShutdown` event to all subscribed plugins
2. **Shutdown hook**: ARO calls `aro_plugin_shutdown()` on each loaded plugin
3. **Unload**: Libraries are closed in reverse dependency order

All execution happens in microseconds for native plugins. The JSON serialization and parsing, while not free, are typically dwarfed by the actual work the plugin does.

## 2.17 Summary

The plugin architecture rests on a few key principles:

- **C ABI for universal compatibility** across languages
- **`aro_plugin_info` as the required primary interface** — it is the single source of truth about what a plugin provides
- **`aro_plugin_execute` as the unified execution entry point** — actions and service calls share one function, distinguished by the dispatch key
- **Lifecycle hooks (`init`/`shutdown`) are optional** — implement them only when you need one-time setup or cleanup
- **JSON for data exchange** with its simplicity and flexibility
- **Explicit memory ownership** to prevent leaks: allocate with `strdup`, free via `aro_plugin_free`
- **Event subscriptions and system objects** for plugins that need deeper runtime integration

Understanding this architecture makes you a more effective plugin author. You know what ARO expects, how data flows, and where problems might arise.

Now let's see how to use plugins in practice.
