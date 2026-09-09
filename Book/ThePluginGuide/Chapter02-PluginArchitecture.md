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
handle: Example
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
- **handle**: The PascalCase namespace the plugin's actions and qualifiers live under
- **provides**: List of components the plugin provides
- **dependencies**: Other plugins this one requires

The `handle` is what callers actually type: a plugin with `handle: Example`
exposes its actions as `Example.Verb` and its qualifiers as
`<value: Example.qualifier>`. Handles are unique across an application — a
second plugin claiming `Example` is loaded without a namespace and logs an
error. The `provides` section tells ARO what type of plugin this is and how to
build it. We'll cover both in Chapter 4.

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

/* OPTIONAL — system object read/write/list.
   All three return a heap-allocated JSON string; none returns a status code. */
char* aro_object_read(const char* identifier, const char* qualifier);
char* aro_object_write(const char* identifier, const char* qualifier, const char* value_json);
char* aro_object_list(const char* pattern);

/* OPTIONAL — forces file-scope initialisation before info is queried.
   Swift SDK plugins need it, because a file-scope `let` is lazy. */
void aro_plugin_register(void);

/* OPTIONAL — receives a callback the plugin can use to invoke ARO feature sets */
void aro_plugin_set_invoke(char* (*invoke)(const char* featureSet, const char* inputJson));

/* REQUIRED if plugin allocates strings — free memory allocated by plugin */
void aro_plugin_free(char* ptr);
```

Those twelve names are the complete set: they are exactly the symbols
`aro build` renames when it links plugins statically into a binary (see
Section 2.16).

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
  "actions": [
    { "name": "Hash", "verbs": ["Hash.Hash", "hash"],
      "role": "own", "prepositions": ["from", "with"] }
  ],
  "qualifiers": [
    { "name": "djb2",  "inputTypes": ["String"], "accepts_parameters": false },
    { "name": "fnv1a", "inputTypes": ["String"], "accepts_parameters": false },
    { "name": "md5",   "inputTypes": ["String"], "accepts_parameters": false }
  ],
  "services": [
    {
      "name": "hash",
      "methods": ["djb2", "fnv1a", "md5"]
    }
  ],
  "system_objects": [
    { "identifier": "hash-cache", "capabilities": ["readable", "writable"] }
  ],
  "events": {
    "subscribes": ["AppStart"],
    "emits":      ["HashComputed"]
  },
  "deprecations": [
    { "feature": "crc32", "message": "Use md5 instead",
      "since": "1.4.0", "remove_in": "2.0.0" }
  ]
}
```

Top-level fields:

- **name**: Plugin identifier (must match `plugin.yaml`)
- **version**: Semantic version
- **actions**: Action descriptors routed through `aro_plugin_execute("Hash", ...)`. The flat shorthand `"actions": ["hash"]` still parses, but the structured form carries the `verbs`, `role`, `prepositions` and `description` that the editor and `aro actions` display.
- **qualifiers**: Qualifier names routed through `aro_plugin_qualifier(name, ...)`. `inputTypes` is camelCase — spell it `input_types` and the runtime silently accepts the qualifier for every type. Each entry may declare `accepts_parameters: true` if the qualifier accepts inline arguments.
- **services**: Named services with their methods, also routed through `aro_plugin_execute("service:<method>", ...)`
- **system_objects**: Objects this plugin manages via `aro_object_read/write/list`. The key is `identifier`, not `name` — an entry keyed on `name` is skipped.
- **events.subscribes**: Event types the plugin wants to receive via `aro_plugin_on_event`
- **events.emits**: Event types this plugin may emit (informational, for tooling)
- **deprecations**: Identifiers scheduled for removal (`feature`, `message`, `since`, `remove_in`)

ARO parses this metadata at load time and registers each capability in the appropriate runtime registry. Unrecognised keys are ignored silently, so a misspelled field costs you the feature rather than an error — check `aro actions` and `aro actions --qualifiers` after a change.

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
| Service method | `service:<method>` | `"service:md5"` |

The service *name* does not appear in the key — the runtime already resolved
which plugin to call before it dispatched, so only the method survives. To
invoke the `md5` method of the `hash` service:

```c
// ARO calls:
aro_plugin_execute("service:md5", "{\"data\":\"hello world\"}")
```

The function returns a newly allocated JSON string. On success it contains the result; on error it contains an `"error"` field (see Section 2.13). ARO calls `aro_plugin_free` on the returned pointer when it is done.

A minimal C implementation:

```c
char* aro_plugin_execute(const char* action, const char* input_json) {
    if (strcmp(action, "service:md5") == 0) {
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
    case "service:md5":
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

Declare system objects in `aro_plugin_info`. Each entry is an object, and the
identity key is `identifier` — an entry keyed on `name` parses into nothing and
the object never registers:

```json
"system_objects": [
  { "identifier": "hash-cache",
    "capabilities": ["readable", "writable", "enumerable"] }
]
```

Then implement the three access functions. All three return a heap-allocated
JSON string; none of them returns a status code:

```c
/* Read a key from the object; return JSON value or null */
char* aro_object_read(const char* identifier, const char* qualifier) {
    if (strcmp(identifier, "hash-cache") == 0) {
        const char* value = cache_get(qualifier);
        return value ? strdup(value) : strdup("null");
    }
    return strdup("null");
}

/* Write a key into the object; report status in the returned JSON */
char* aro_object_write(const char* identifier, const char* qualifier,
                       const char* value_json) {
    if (strcmp(identifier, "hash-cache") == 0) {
        cache_set(qualifier, value_json);
        return strdup("{\"ok\": true}");
    }
    return strdup("{\"error\": \"Unknown object\"}");
}

/* List entries matching a pattern; return JSON array.
   Note the single argument — the pattern, not the object id. */
char* aro_object_list(const char* pattern) {
    return cache_list_keys_as_json(pattern);
}
```

ARO calls `aro_plugin_free` on any pointer returned by these functions.

> **Known gap.** The C SDK's info-JSON builder emits `"name"` rather than
> `"identifier"`, so system objects declared through the SDK's macros do not
> register with the runtime. Write `aro_plugin_info` by hand if you need system
> objects, until that is fixed (GitLab #556).

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
- `aro_object_write`
- `aro_object_list`

**`aro_plugin_info` is on that list.** It is tempting to return a `static const
char*` from it — the string never changes, after all — but ARO frees what it
gets back, and `free()` on a static buffer is undefined behaviour. Return a
fresh `strdup` (or a `CString::into_raw`) every time.

Strings passed **into** your plugin (the `action`, `input_json`, `event_type`, `data_json`, `key`, and `value_json` parameters) are owned by ARO. Never free them.

Memory leaks in plugins are insidious—they affect the entire ARO runtime. Use tools like Valgrind (Linux) or Instruments (macOS) to verify your plugin doesn't leak.

## 2.12 Python Plugins: A Different Path

Python plugins follow the same conceptual model but use a different transport mechanism.

Instead of loading a dynamic library, ARO spawns `python3 -c` with a small
generated driver script. The script inserts the plugin directory on
`sys.path`, imports one function out of the plugin module, calls it with the
input JSON, and prints the result:

```python
# What ARO actually runs, per call
import sys, json, base64
sys.path.insert(0, '/path/to/Plugins/plugin-text/src')
from plugin import aro_action_analyze
input_json = base64.b64decode('...').decode('utf-8')
print(aro_action_analyze(input_json))
```

The Python plugin must define module-level functions following a naming convention:

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

**One process per call.** This is the single most important thing to know
about Python plugins: ARO does not keep the interpreter alive between calls.
Every action invocation, and every qualifier invocation, forks a fresh
`python3`, re-imports the module, and tears it down. Module-level state does
not survive — a cache populated on one call is empty on the next, and a model
loaded on one call is reloaded on the next. Design Python plugins to be
stateless, and push anything expensive into a process the plugin talks to
rather than into the plugin's own globals.

The per-call overhead (interpreter startup plus imports, easily 50–100 ms and
much more once a heavy library is imported) makes Python plugins unsuitable
for high-frequency operations. For tasks where the computation itself takes
seconds and does not need warm state, the overhead is tolerable.

## 2.13 The UnifiedPluginLoader

ARO uses a `UnifiedPluginLoader` that delegates to specialized hosts based on the `provides` type:

```
UnifiedPluginLoader
    ├── NativePluginHost    → C, C++, Rust AND Swift plugins
    ├── PythonPluginHost    → Python plugins
    └── AROFilePlugin       → aro-files and aro-templates providers
```

There is no separate Swift host. A Swift plugin's `@_cdecl` exports are
binary-compatible with the C ABI, so Swift plugins are `dlopen`ed through
`NativePluginHost` exactly like a C plugin — which is why everything this
chapter says about the C ABI applies verbatim to Swift.

**Lazy loading.** When a `provides` entry declares its `actions:` in
`plugin.yaml`, the loader registers action *stubs* at startup and defers the
`dlopen` (or the `cargo build`, or the first `python3`) until an ARO statement
actually invokes one of them. Applications that ship several plugins but use
one per request start much faster this way. Omit `actions:` and the plugin is
loaded eagerly at startup.

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

Qualifiers are stricter than actions here. `aro_plugin_qualifier` must return
either `{"result": <value>}` or `{"error": "<message>"}` — nothing else. An
action may return any JSON object and let the caller pick fields off it, but a
qualifier that returns `{"value": "HELLO"}`, or a bare `"HELLO"`, fails with
*Plugin returned neither result nor error*. Wrap the transformed value in
`result` and nothing more; wrapping twice (`{"result": {"result": …}}`) binds
the inner object rather than the value.

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
2. **Handle resolution**: the root-level `handle:` (or, with a deprecation warning, a legacy `handler:` inside `provides:`) becomes the plugin's namespace, and the loader checks no other plugin has claimed it
3. **Loading**: `libhash.dylib` is loaded into memory via `dlopen`
4. **Register**: if the library exports `aro_plugin_register`, ARO calls it so file-scope initialisation runs before the metadata is read
5. **Info**: ARO calls `aro_plugin_info()` → receives JSON declaring actions, qualifiers, services, and system objects, then frees the returned pointer with `aro_plugin_free`
6. **Init**: ARO calls `aro_plugin_init()` if present → plugin warms up its cache
7. **Registration**: the `Hash` action (under both `hash` and `Hash.hash`), the `djb2`/`fnv1a`/`md5` qualifiers (as `Hash.djb2` and friends), the `hash` service, and the `hash-cache` system object are registered in their respective runtime registries
8. **Event subscription**: ARO subscribes the plugin to `AppStart` events (as declared in `events.subscribes`)

### Execution trace

When ARO executes `Call the <hash> from the <plugin-hash: djb2> with { data: "hello" }.`:

1. **Service lookup**: ARO finds the service registered under `plugin-hash`
2. **Method resolution**: `djb2` is the method named by the object qualifier
3. **Argument serialization**: `{ data: "hello" }` becomes `{"data":"hello"}`
4. **Dispatch**: ARO calls `aro_plugin_execute("service:djb2", "{\"data\":\"hello\"}")`
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

### Compiled binaries

`aro build` does not copy plugins next to the binary; it links them *into* it.
Each plugin's object code is rewritten with `llvm-objcopy --redefine-sym` so
its C ABI symbols carry a per-plugin prefix — `aro_plugin_info` becomes
`aro_static_plugin_hash__aro_plugin_info` — and the runtime is handed the
resulting function pointers at startup. That prefixing is why every plugin can
export the same twelve names without colliding, and why the resulting binary
needs no `Plugins/` directory beside it. Python plugins take the same route
through an embedded `libpython3`: source and dependencies are baked into the
binary and run in-process, so the target machine needs no Python installed.

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
