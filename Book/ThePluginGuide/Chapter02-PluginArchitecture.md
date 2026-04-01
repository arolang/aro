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
4. **Initialization**: ARO calls `aro_plugin_init()` to get service metadata
5. **Registration**: Services are registered in the runtime's service registry
6. **Execution**: When ARO code calls a plugin service, the registered function is invoked

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

All native plugins must expose functions using C calling conventions. In Swift, you use `@_cdecl`:

```swift
@_cdecl("aro_plugin_init")
public func pluginInit() -> UnsafePointer<CChar> {
    // Return plugin metadata as JSON
}
```

In Rust, you use `#[no_mangle]` and `extern "C"`:

```rust
#[no_mangle]
pub extern "C" fn aro_plugin_init() -> *const c_char {
    // Return plugin metadata as JSON
}
```

In C and C++, it's natural—C is the lingua franca:

```c
const char* aro_plugin_init(void) {
    // Return plugin metadata as JSON
}
```

The C ABI ensures that regardless of what language the plugin is written in, ARO can call its functions using the same mechanism.

## 2.6 Plugin Initialization

When ARO loads a plugin library, it looks for a function named `aro_plugin_init`. This function must return a JSON string describing the plugin's services:

```json
{
  "services": [
    {
      "name": "hash",
      "symbol": "hash_service_call",
      "methods": ["djb2", "fnv1a", "md5"]
    }
  ]
}
```

Each service entry declares:

- **name**: How the service will be referenced in ARO code
- **symbol**: The C function name that handles service calls
- **methods**: Optional list of available methods

ARO parses this metadata and registers each service in its internal registry. When your ARO code later calls `<plugin-hash: djb2>`, ARO knows which function to invoke.

## 2.7 Service Function Signature

Service functions follow a standard signature:

```c
int32_t service_call(
    const char* method,      // Method name (e.g., "djb2")
    const char* args_json,   // Input arguments as JSON
    char** result_json       // Output: result as JSON
);
```

Or in Swift:

```swift
@_cdecl("hash_service_call")
public func serviceCall(
    _ methodPtr: UnsafePointer<CChar>,
    _ argsPtr: UnsafePointer<CChar>,
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    let method = String(cString: methodPtr)
    let argsJSON = String(cString: argsPtr)

    // Process the request...

    let result = "{\"hash\": \"abc123\"}"
    resultPtr.pointee = strdup(result)
    return 0  // Success
}
```

The return value indicates success (0) or failure (non-zero). Error details should be included in the result JSON.

## 2.8 JSON-Based Communication

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

## 2.9 Memory Management

Memory management across the C ABI requires careful attention. The basic rule:

**The allocator frees.**

If ARO allocates memory and passes it to your plugin, ARO will free it. If your plugin allocates memory and returns it to ARO, your plugin must provide a way to free it.

The standard pattern uses `strdup()` for allocating result strings:

```c
// Plugin allocates with strdup()
char* result = strdup("{\"status\": \"ok\"}");
*result_json = result;

// Later, ARO will call free() on this pointer
```

For complex plugins, you can provide a custom free function:

```c
void aro_plugin_free(char* ptr) {
    free(ptr);
}
```

ARO will call this function (if provided) to clean up memory allocated by your plugin.

Memory leaks in plugins can be insidious—they affect the entire ARO runtime. Use tools like Valgrind (Linux) or Instruments (macOS) to verify your plugin doesn't leak.

## 2.10 Python Plugins: A Different Path

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

## 2.11 The UnifiedPluginLoader

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
3. Call the initialization function
4. Register services with ARO's runtime
5. Handle cleanup on shutdown

This abstraction means you don't need to worry about the loading mechanics—just follow the conventions for your plugin type, and ARO handles the rest.

## 2.12 Thread Safety

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

## 2.13 Error Handling

Errors in plugins should be reported through the return value and result JSON:

```c
if (invalid_input) {
    *result_json = strdup("{\"error\": \"Invalid input: expected string\"}");
    return 1;  // Non-zero indicates error
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

## 2.14 Putting It All Together

Let's trace a complete plugin call:

1. **ARO Code**: `Call the <hash> from the <plugin-hash: djb2> with { data: "hello" }.`

2. **Service Lookup**: ARO finds `plugin-hash` in the registry, resolves `djb2` method

3. **Argument Serialization**: `{ data: "hello" }` becomes `{"data":"hello"}`

4. **Function Call**: ARO calls `hash_service_call("djb2", "{\"data\":\"hello\"}", &result)`

5. **Plugin Processing**: Your code parses JSON, computes hash, builds result

6. **Result Return**: Plugin sets `result = "{\"hash\":\"...\"}"` and returns 0

7. **Result Parsing**: ARO parses the JSON result

8. **Binding**: The result is bound to `<hash>` in ARO's symbol table

9. **Continuation**: ARO continues with the next statement

All of this happens in microseconds for native plugins. The JSON serialization and parsing, while not free, are typically dwarfed by the actual work the plugin does.

## 2.15 Summary

The plugin architecture rests on a few key principles:

- **C ABI for universal compatibility** across languages
- **JSON for data exchange** with its simplicity and flexibility
- **Explicit memory ownership** to prevent leaks
- **Uniform interface** hiding implementation complexity

Understanding this architecture makes you a more effective plugin author. You know what ARO expects, how data flows, and where problems might arise.

Now let's see how to use plugins in practice.
