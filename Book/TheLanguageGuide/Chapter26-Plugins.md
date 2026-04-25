# Chapter 26: Plugins

*"Package and share your extensions."*

---

## 26.1 What Are Plugins?

Plugins extend ARO with custom actions, services, and feature sets. They allow you to package extensions together, share them across projects, and distribute them to other developers.

ARO supports plugins written in multiple languages:

| Language | Plugin Type | Use Case |
|----------|-------------|----------|
| **ARO** | `.aro` files | Reusable feature sets |
| **Swift** | Swift Package | Native integration with ARO runtime |
| **Rust** | FFI Plugin | Performance-critical operations |
| **C/C++** | FFI Plugin | System-level integrations |
| **Python** | Subprocess | AI/ML, data science libraries |

A plugin can contain:

| Type | Adds | Invocation Pattern | Example |
|------|------|-------------------|---------|
| **Actions** | New verbs | `<Verb> the <result> from <object>.` | `Geocode the <coords> from <address>.` |
| **Services** | External integrations | `Call from <service: method>` | `Call from <zip: compress>` |
| **Feature Sets** | Reusable business logic | Triggered by events | `FormatCSV`, `SendNotification` |

---

## 26.2 Package Manager

ARO includes a Git-based package manager for installing and managing plugins.

### Installing Plugins

Install a plugin from a Git repository:

```bash
aro add git@github.com:arolang/plugin-swift-hello.git
```

Specify a version or branch:

```bash
aro add git@github.com:arolang/plugin-rust-csv.git@v1.0.0
aro add git@github.com:arolang/plugin-python-markdown.git@main
```

### Removing Plugins

Remove an installed plugin:

```bash
aro remove plugin-swift-hello
```

### Listing Plugins

List all installed plugins:

```bash
aro plugins list
```

### Plugin Commands

| Command | Description |
|---------|-------------|
| `aro add <url>[@ref]` | Install a plugin from Git |
| `aro remove <name>` | Remove an installed plugin |
| `aro plugins list` | List all installed plugins |
| `aro plugins update` | Update all plugins to latest |
| `aro plugins validate` | Check plugin integrity |
| `aro plugins export` | Export plugin sources to `.aro-sources` |
| `aro plugins restore` | Restore plugins from `.aro-sources` |

---

<div style="text-align: center; margin: 2em 0;">
<svg xmlns="http://www.w3.org/2000/svg" width="530" height="175" font-family="sans-serif">
  <!-- Swift plugin (indigo) -->
  <rect x="10" y="10" width="115" height="55" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="67" y="32" text-anchor="middle" font-size="11" fill="#4338ca" font-weight="bold">Swift</text>
  <text x="67" y="50" text-anchor="middle" font-size="9" fill="#4338ca">@_cdecl</text>

  <!-- Rust plugin (green) -->
  <rect x="140" y="10" width="115" height="55" rx="4" fill="#d1fae5" stroke="#22c55e" stroke-width="2"/>
  <text x="197" y="32" text-anchor="middle" font-size="11" fill="#166534" font-weight="bold">Rust</text>
  <text x="197" y="50" text-anchor="middle" font-size="9" fill="#166534">#[no_mangle]</text>

  <!-- C plugin (amber) -->
  <rect x="270" y="10" width="115" height="55" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="327" y="32" text-anchor="middle" font-size="11" fill="#92400e" font-weight="bold">C / C++</text>
  <text x="327" y="50" text-anchor="middle" font-size="9" fill="#92400e">standard C ABI</text>

  <!-- Python plugin (red) -->
  <rect x="400" y="10" width="120" height="55" rx="4" fill="#fee2e2" stroke="#ef4444" stroke-width="2"/>
  <text x="460" y="32" text-anchor="middle" font-size="11" fill="#991b1b" font-weight="bold">Python</text>
  <text x="460" y="50" text-anchor="middle" font-size="9" fill="#991b1b">subprocess</text>

  <!-- Lines from PluginHost up to each plugin -->
  <line x1="67" y1="65" x2="200" y2="120" stroke="#9ca3af" stroke-width="1.5"/>
  <line x1="197" y1="65" x2="220" y2="120" stroke="#9ca3af" stroke-width="1.5"/>
  <line x1="327" y1="65" x2="290" y2="120" stroke="#9ca3af" stroke-width="1.5"/>
  <line x1="460" y1="65" x2="310" y2="120" stroke="#9ca3af" stroke-width="1.5"/>

  <!-- PluginHost / ARO Runtime (dark, bottom center) -->
  <rect x="145" y="120" width="240" height="45" rx="4" fill="#1f2937" stroke="#1f2937" stroke-width="2"/>
  <text x="265" y="140" text-anchor="middle" font-size="11" fill="#ffffff" font-weight="bold">PluginHost</text>
  <text x="265" y="156" text-anchor="middle" font-size="9" fill="#ffffff">ARO Runtime</text>
</svg>
</div>

## 26.3 Plugin Structure

All plugins live in the `Plugins/` directory and require a `plugin.yaml` manifest:

```
MyApp/
├── main.aro
├── openapi.yaml
└── Plugins/
    └── my-plugin/
        ├── plugin.yaml      ← Required manifest
        ├── features/        ← ARO feature sets
        │   └── helpers.aro
        └── Sources/         ← Swift/Native sources
            └── MyPlugin.swift
```

### The plugin.yaml Manifest

Every plugin must have a `plugin.yaml` file:

```yaml
name: my-plugin
version: 1.0.0
description: "A helpful plugin for ARO"
author: "Your Name"
license: MIT
aro-version: ">=0.1.0"

source:
  git: "git@github.com:yourname/my-plugin.git"
  ref: "main"

provides:
  - type: aro-files
    path: features/
  - type: swift-plugin
    path: Sources/

dependencies:
  other-plugin:
    git: "git@github.com:arolang/other-plugin.git"
    ref: "v1.0.0"
```

### Required Fields

| Field | Description |
|-------|-------------|
| `name` | Plugin name (lowercase, hyphens only) |
| `version` | Semantic version (e.g., "1.0.0") |
| `provides` | List of components this plugin provides |

### Provide Types

| Type | Description |
|------|-------------|
| `aro-files` | ARO feature set files |
| `swift-plugin` | Swift package |
| `rust-plugin` | Rust library (FFI) |
| `c-plugin` | C/C++ library (FFI) |
| `python-plugin` | Python module |

### Provide Entry Fields

Each entry in `provides:` can have these fields:

| Field | Required | Description |
|-------|----------|-------------|
| `type` | Yes | Plugin type (see table above) |
| `path` | Yes | Path to source files or library |
| `handler` | No | Qualifier namespace prefix (legacy; prefer root-level `handle:`) |
| `build` | No | Build configuration (for compiled plugins) |
| `python` | No | Python configuration (for python-plugin) |

The qualifier namespace is declared via the root-level `handle:` field (PascalCase, canonical). Qualifiers from this plugin are accessed as `Handle.qualifier` in ARO code. If omitted, the plugin name is used as the namespace. The legacy `handler:` field inside `provides:` still works but emits a deprecation warning.

**Example:**

```yaml
name: plugin-math
version: 1.0.0
handle: Math          # PascalCase root-level handle (canonical)
provides:
  - type: swift-plugin
    path: Sources/
    # handler: math   # Legacy — use root-level handle: instead
```

Qualifiers are accessed as `Math.round`, `Math.abs` in ARO code.

See section 22.5 for complete documentation on plugin qualifiers.

---

## 26.4 ARO File Plugins

The simplest plugins are pure ARO files that provide reusable feature sets.

**plugin.yaml:**

```yaml
name: string-helpers
version: 1.0.0
provides:
  - type: aro-files
    path: features/
```

**features/strings.aro:**

```aro
(* FormatTitle — Capitalize first letter of each word *)
(FormatTitle: String Operations) {
    Extract the <text> from the <input: text>.
    Transform the <title: titlecase> from <text>.
    Return an <OK: status> with <title>.
}

(* TruncateText — Shorten text with ellipsis *)
(TruncateText: String Operations) {
    Extract the <text> from the <input: text>.
    Extract the <max-length> from the <input: maxLength>.
    Compute the <length: length> from <text>.
    match <length> > <max-length> {
        case true {
            Transform the <truncated: substring> from <text>.
            Create the <result> with <truncated> ++ "...".
        }
        case false {
            Create the <result> with <text>.
        }
    }
    Return an <OK: status> with <result>.
}
```

Feature sets from plugins are automatically available in your application with a qualified name:

```aro
(* Use plugin feature set *)
(Format User Name: User Processing) {
    Extract the <name> from the <user: fullName>.
    Emit a <FormatTitle: event> with { text: <name> }.
    Return an <OK: status> with <name>.
}
```

---

## 26.5 Plugin Qualifiers

Plugins can provide **qualifiers** — named transformations that can be applied to values in ARO expressions using the `<value: handler.qualifier>` syntax.

### What Are Plugin Qualifiers?

Qualifiers extend the built-in qualifier operations (like `length`, `uppercase`, `hash`) with plugin-defined transformations. They are ideal for domain-specific operations that don't belong in the standard library.

```aro
(* Built-in qualifiers *)
Compute the <len: length> from the <text>.
Compute the <upper: uppercase> from the <greeting>.

(* Plugin qualifiers with handler namespace *)
Compute the <sorted: stats.sort> from the <numbers>.
Log <numbers: collections.reverse> to the <console>.
```

### The Handle Namespace

Each plugin that provides qualifiers declares a root-level `handle:` field (PascalCase) in `plugin.yaml`. This becomes the **namespace prefix** for all qualifiers from that plugin.

```yaml
# plugin.yaml
name: plugin-swift-collection
version: 1.0.0
handle: Collections       # PascalCase root-level handle (canonical)
provides:
  - type: swift-plugin
    path: Sources/
```

In ARO code, qualifiers are accessed as `Handle.qualifier`:

```aro
(* handler = collections, qualifier = reverse *)
Compute the <reversed: collections.reverse> from the <list>.

(* Works in expressions too *)
Log <list: collections.reverse> to the <console>.
```

### Registering Qualifiers in C/Swift

Native plugins register qualifiers by including them in `aro_plugin_info()` and providing an `aro_plugin_qualifier()` function:

```c
char* aro_plugin_info(void) {
    return strdup("{\"name\":\"plugin-c-list\",\"qualifiers\":[{"
        "\"name\":\"first\",\"inputTypes\":[\"array\"]},"
        "{\"name\":\"last\",\"inputTypes\":[\"array\"]},"
        "{\"name\":\"size\",\"inputTypes\":[\"array\",\"string\"]}"
    "]}");
}

char* aro_plugin_qualifier(const char* qualifier_name, const char* input_json) {
    // input_json = {"value": <the_input_value>}
    cJSON* input = cJSON_Parse(input_json);
    cJSON* value = cJSON_GetObjectItem(input, "value");

    if (strcmp(qualifier_name, "first") == 0) {
        // Return first element
        cJSON* result = cJSON_CreateObject();
        cJSON_AddItemToObject(result, "result", cJSON_Duplicate(
            cJSON_GetArrayItem(value, 0), 1));
        char* out = cJSON_Print(result);
        cJSON_Delete(input); cJSON_Delete(result);
        return out;
    }
    // ...
}
```

**plugin.yaml:**

```yaml
name: plugin-c-list
version: 1.0.0
handle: List            # qualifiers accessed as List.first, List.last, List.size
provides:
  - type: c-plugin
    path: src/
```

**Usage:**

```aro
Create the <numbers> with [10, 20, 30, 40, 50].
Compute the <first-element: list.first> from the <numbers>.
Compute the <last-element: list.last> from the <numbers>.
Compute the <count: list.size> from the <numbers>.
```

### Registering Qualifiers in Python

Python plugins include a `qualifiers` list in `aro_plugin_info()` and an `aro_plugin_qualifier()` function:

```python
def aro_plugin_info():
    return {
        "name": "plugin-python-stats",
        "version": "1.0.0",
        "qualifiers": [
            {"name": "sort",   "inputTypes": ["array"]},
            {"name": "min",    "inputTypes": ["array"]},
            {"name": "max",    "inputTypes": ["array"]},
            {"name": "sum",    "inputTypes": ["array"]},
            {"name": "avg",    "inputTypes": ["array"]},
            {"name": "unique", "inputTypes": ["array"]},
        ]
    }

def aro_plugin_qualifier(qualifier_name, input_json):
    import json
    data = json.loads(input_json)
    value = data["value"]
    if qualifier_name == "sort":
        return json.dumps({"result": sorted(value)})
    elif qualifier_name == "min":
        return json.dumps({"result": min(value)})
    # ...
```

**plugin.yaml:**

```yaml
name: plugin-python-stats
version: 1.0.0
handle: Stats           # qualifiers accessed as Stats.sort, Stats.min, etc.
provides:
  - type: python-plugin
    path: src/
```

**Usage:**

```aro
Create the <numbers> with [5, 2, 8, 1, 9, 3].
Compute the <sorted-numbers: stats.sort> from the <numbers>.
Compute the <minimum: stats.min> from the <numbers>.
Compute the <total: stats.sum> from the <numbers>.
```

### Input and Output Format

Plugin qualifiers receive input as JSON:

```json
{"value": <the_input_value>}
```

And return output as JSON:

```json
{"result": <the_output_value>}
```

Or on error:

```json
{"error": "description of what went wrong"}
```

### Qualifier Input Types

The `inputTypes` field restricts which value types a qualifier accepts:

| Type | Values |
|------|--------|
| `array` | Lists |
| `string` | Text values |
| `number` | Integers and floats |
| `object` | Dictionaries |

If `inputTypes` is omitted, the qualifier accepts all types.

---

## 26.6 Swift Plugins

Swift plugins provide the deepest integration with ARO, allowing custom actions and services.

### Creating a Swift Action Plugin

**Directory Structure:**

```
GeocodePlugin/
├── plugin.yaml
├── Package.swift
└── Sources/GeocodePlugin/
    ├── GeocodeAction.swift
    └── Registration.swift
```

**plugin.yaml:**

```yaml
name: geocode-plugin
version: 1.0.0
provides:
  - type: swift-plugin
    path: .

build:
  swift:
    minimum-version: "6.2"
```

**GeocodeAction.swift:**

```swift
import ARORuntime

public struct GeocodeAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["Geocode"]
    public static let validPrepositions: Set<Preposition> = [.from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        let address: String = try context.require(object.base)
        let coordinates = try await geocode(address)
        context.bind(result.base, value: coordinates)
        return coordinates
    }

    private func geocode(_ address: String) async throws -> [String: Double] {
        // Implementation
        return ["latitude": 37.7749, "longitude": -122.4194]
    }
}
```

**Registration.swift:**

```swift
import ARORuntime

@_cdecl("aro_plugin_register")
public func registerPlugin() {
    ActionRegistry.shared.register(GeocodeAction.self)
}
```

**Usage:**

```aro
Geocode the <coordinates> from the <address>.
```

---

## 26.7 Native Plugins (Rust/C)

Native plugins use a C ABI interface for high-performance operations.

### The C ABI Contract

`aro_plugin_info` and `aro_plugin_free` are the only **required** exports. Everything else is optional and implemented only when your plugin needs that capability:

```c
/* ---- REQUIRED ---- */

// Return JSON metadata describing everything this plugin provides
char* aro_plugin_info(void);

// Free any string returned by the plugin
void aro_plugin_free(char* ptr);

/* ---- OPTIONAL: implement only what you need ---- */

// One-time initialization (DB connections, model loading, etc.)
void aro_plugin_init(void);

// Cleanup on unload (close connections, flush buffers, etc.)
void aro_plugin_shutdown(void);

// Execute an action or service method — only needed if you provide actions or services
// Service calls arrive as action="service:<method>"
char* aro_plugin_execute(const char* action, const char* input_json);

// Execute a qualifier transformation — only needed if you provide qualifiers
char* aro_plugin_qualifier(const char* name, const char* input_json);

// Handle a subscribed event — only needed if you subscribe to events
void aro_plugin_on_event(const char* event_type, const char* data);

// System object read — only needed if you provide readable system objects
char* aro_object_read(const char* id, const char* qualifier);

// System object write — only needed if you provide writable system objects
char* aro_object_write(const char* id, const char* qualifier, const char* value);

// System object list — only needed if you provide enumerable system objects
char* aro_object_list(const char* pattern);
```

`aro_plugin_invoke` is a **callback provided by the runtime**, not an export you implement. The runtime sets it before calling any plugin function, enabling hybrid plugins to call back into ARO feature sets:

```c
// Runtime-provided: call an ARO feature set from native code
typedef char* (*aro_invoke_fn)(const char* feature_set, const char* input_json);
extern aro_invoke_fn aro_plugin_invoke;
```

### Rust Plugin Example

**plugin.yaml:**

```yaml
name: plugin-rust-csv
version: 1.0.0
provides:
  - type: rust-plugin
    path: src/
    build:
      cargo-target: release
      output: target/release/libcsv_plugin.dylib
```

**src/lib.rs:**

```rust
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

// aro_plugin_info and aro_plugin_free are the only required exports.
#[no_mangle]
pub extern "C" fn aro_plugin_info() -> *mut c_char {
    let info = r#"{
        "name": "plugin-rust-csv",
        "version": "1.0.0",
        "actions": [
            {
                "name": "ParseCSV",
                "verbs": ["parse-csv"],
                "role": "own",
                "prepositions": ["from"]
            }
        ]
    }"#;
    CString::new(info).unwrap().into_raw()
}

// aro_plugin_execute is optional — implement it only if providing actions or services.
// The input JSON now includes result/source descriptors, preposition, _context, and _with.
#[no_mangle]
pub extern "C" fn aro_plugin_execute(
    action: *const c_char,
    input_json: *const c_char,
) -> *mut c_char {
    let action = unsafe { CStr::from_ptr(action) }.to_str().unwrap_or("");
    let _input = unsafe { CStr::from_ptr(input_json) }.to_str().unwrap_or("{}");
    // Parse _input to access: "data", "preposition", "result", "source", "_context", "_with"
    let result = match action {
        "parse-csv" => r#"{"rows": [], "count": 0}"#,
        _ => r#"{"error": "unknown action"}"#,
    };
    CString::new(result).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn aro_plugin_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { let _ = CString::from_raw(ptr); }
    }
}
```

### C Plugin Example

**plugin.yaml:**

```yaml
name: plugin-c-hash
version: 1.0.0
provides:
  - type: c-plugin
    path: src/
    build:
      compiler: clang
      flags: ["-O2", "-fPIC", "-shared"]
      output: libhash_plugin.dylib
```

**src/hash_plugin.c:**

```c
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* aro_plugin_info and aro_plugin_free are the only required exports. */
char* aro_plugin_info(void) {
    const char* info =
        "{"
        "\"name\":\"plugin-c-hash\","
        "\"version\":\"1.0.0\","
        "\"actions\":[{"
        "  \"name\":\"ComputeHash\","
        "  \"verbs\":[\"hash\",\"computehash\"],"
        "  \"role\":\"own\","
        "  \"prepositions\":[\"from\"]"
        "}]"
        "}";
    char* result = malloc(strlen(info) + 1);
    strcpy(result, info);
    return result;
}

/* aro_plugin_execute is optional — implement only if providing actions or services.
   Input JSON includes: "data", "preposition", "result", "source", "_context", "_with". */
char* aro_plugin_execute(const char* action, const char* input) {
    char* result = malloc(256);
    if (strcmp(action, "hash") == 0 || strcmp(action, "computehash") == 0) {
        /* Read "data" from input JSON, compute hash, return result */
        snprintf(result, 256, "{\"hash\":\"abc123\"}");
    } else {
        snprintf(result, 256, "{\"error\":\"unknown action: %s\"}", action);
    }
    return result;
}

void aro_plugin_free(char* ptr) {
    if (ptr) free(ptr);
}
```

---

## 26.8 Python Plugins

Python plugins run as subprocesses, enabling access to Python's ecosystem.

### Required Interface

```python
def aro_plugin_info():
    """Return plugin metadata as dict"""
    return {
        "name": "my-plugin",
        "version": "1.0.0",
        "actions": ["analyze", "transform"]
    }

def aro_action_analyze(input_json):
    """Execute the analyze action"""
    import json
    params = json.loads(input_json)
    result = {"analyzed": True}
    return json.dumps(result)
```

### Python Plugin Example

**plugin.yaml:**

```yaml
name: plugin-python-markdown
version: 1.0.0
provides:
  - type: python-plugin
    path: src/
    python:
      min-version: "3.9"
      requirements: requirements.txt
```

**src/plugin.py:**

```python
import json
import re

def aro_plugin_info():
    return {
        "name": "plugin-python-markdown",
        "version": "1.0.0",
        "actions": ["to-html", "extract-links"]
    }

def aro_action_to_html(input_json):
    params = json.loads(input_json)
    markdown = params.get("data", "")
    html = markdown_to_html(markdown)
    return json.dumps({"html": html})

def aro_action_extract_links(input_json):
    params = json.loads(input_json)
    markdown = params.get("data", "")
    links = re.findall(r'\[(.+?)\]\((.+?)\)', markdown)
    return json.dumps({"links": [{"text": t, "url": u} for t, u in links]})

def markdown_to_html(md):
    # Simple conversion
    html = re.sub(r'^# (.+)$', r'<h1>\1</h1>', md, flags=re.MULTILINE)
    html = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', html)
    return html
```

---

## 26.9 Lifecycle Hooks

Stateful plugins can perform one-time initialization and cleanup by implementing lifecycle hooks. Both are optional — only add them if your plugin needs them.

```c
/* Called once after the plugin is loaded, before any execute calls */
void aro_plugin_init(void) {
    db_pool = open_connection(getenv("DB_URL"));
}

/* Called before the plugin is unloaded */
void aro_plugin_shutdown(void) {
    close_connection(db_pool);
}
```

In Swift (using the `AROPluginSDK`):

```swift
@AROPlugin(handle: "Postgres", version: "1.0.0")
struct PostgresPlugin {

    @OnInit
    static func setup() {
        pool = PostgresConnectionPool(url: ProcessInfo.processInfo.environment["DB_URL"]!)
    }

    @OnShutdown
    static func cleanup() {
        pool.close()
    }
}
```

---

## 26.9b Event Support

Plugins can subscribe to and emit domain events. Declare subscriptions in `aro_plugin_info` and implement `aro_plugin_on_event` to receive them:

**aro_plugin_info JSON:**

```json
{
  "name": "plugin-notifier",
  "version": "1.0.0",
  "events": {
    "emits": ["NotificationSent"],
    "subscribes": ["UserCreated", "OrderPlaced"]
  }
}
```

**C handler:**

```c
void aro_plugin_on_event(const char* event_type, const char* data) {
    if (strcmp(event_type, "UserCreated") == 0) {
        /* Parse data JSON and send welcome notification */
    } else if (strcmp(event_type, "OrderPlaced") == 0) {
        /* Parse data JSON and send order confirmation */
    }
}
```

**Swift (SDK):**

```swift
@OnEvent("UserCreated")
func handleUserCreated(event: EventData) {
    let userId = event.string("userId") ?? "unknown"
    sendWelcomeEmail(to: userId)
}
```

---

## 26.9c System Objects

Plugins can provide custom system objects that integrate with ARO's Source/Sink model. System objects appear as native ARO objects and are accessed with familiar qualifier syntax:

```aro
(* Using a Redis system object provided by a plugin *)
Store the <user-data> to the <redis: users/42>.
Retrieve the <cached> from the <redis: sessions/abc>.
```

Declare capabilities in `aro_plugin_info`:

```json
{
  "name": "plugin-redis",
  "version": "1.0.0",
  "system_objects": [
    {
      "identifier": "redis",
      "capabilities": ["readable", "writable", "enumerable"],
      "description": "Redis key-value store"
    }
  ]
}
```

Then implement the corresponding ABI functions:

| Capability | Function to implement | ARO usage |
|------------|----------------------|-----------|
| `readable` | `aro_object_read(id, qualifier)` | `Retrieve the <x> from the <redis: key>` |
| `writable` | `aro_object_write(id, qualifier, value)` | `Store the <x> to the <redis: key>` |
| `enumerable` | `aro_object_list(pattern)` | `Retrieve the <keys> from the <redis: *>` |

```c
char* aro_object_read(const char* id, const char* qualifier) {
    const char* value = redis_get(qualifier, id);
    /* Return JSON: {"value": <the_value>} */
    char* out = malloc(256);
    snprintf(out, 256, "{\"value\":\"%s\"}", value ? value : "");
    return out;
}

char* aro_object_write(const char* id, const char* qualifier, const char* value) {
    redis_set(qualifier, id, value);
    return strdup("{\"stored\":true}");
}
```

---

## 26.9d Hybrid Plugins: Calling Back into ARO

Plugins that combine native performance with ARO business logic can call ARO feature sets from native code using `aro_plugin_invoke`. The runtime provides this callback before any plugin function is called:

```c
typedef char* (*aro_invoke_fn)(const char* feature_set, const char* input_json);
extern aro_invoke_fn aro_plugin_invoke;   /* set by the runtime */
```

Usage from a native action:

```c
char* aro_plugin_execute(const char* action, const char* input_json) {
    if (strcmp(action, "process-order") == 0) {
        /* Do native computation (hashing, compression, etc.) */
        const char* processed = do_native_work(input_json);

        /* Call back into an ARO feature set for business logic */
        char* validation_result = aro_plugin_invoke(
            "Validate Order: Order Validation",
            processed
        );

        /* Use the result, then free it */
        char* out = build_response(validation_result);
        aro_plugin_free(validation_result);
        return out;
    }
    return strdup("{\"error\":\"unknown action\"}");
}
```

Swift SDK equivalent:

```swift
let result = try ARORuntime.invoke(
    "Validate Order: Order Validation",
    input: ["order": orderData]
)
```

This enables the **hybrid plugin pattern**: native code handles computation (Argon2 hashing, JWT signing, image processing), while ARO feature sets handle business logic (authentication workflows, validation rules).

---

## 26.10 Plugin Dependencies

Plugins can depend on other plugins:

```yaml
name: my-plugin
version: 1.0.0

dependencies:
  string-helpers:
    git: "git@github.com:arolang/plugin-string-helpers.git"
    ref: "v1.0.0"

  csv-tools:
    git: "git@github.com:arolang/plugin-csv-tools.git"
    ref: "main"
```

When installing a plugin, ARO automatically resolves and installs dependencies in the correct order.

---

## 26.11 Choosing a Plugin Type

| If you need... | Choose |
|----------------|--------|
| Reusable ARO feature sets | ARO files |
| Deep ARO integration | Swift plugin |
| Maximum performance | Rust plugin |
| System-level operations | C plugin |
| Python libraries (ML, etc.) | Python plugin |

### Performance Considerations

| Type | Overhead | Best For |
|------|----------|----------|
| ARO files | None | Business logic |
| Swift | None | Most extensions |
| Rust/C | FFI call | CPU-intensive |
| Python | Process spawn | One-time operations |

---

## 26.12 Publishing Plugins

1. Create a Git repository with `plugin.yaml`
2. Tag releases following semantic versioning
3. Document installation in README
4. Publish to GitHub (or any Git host)

**Example README:**

````markdown
# my-plugin

Install:
```bash
aro add git@github.com:yourname/my-plugin.git
```

## Actions

- `<MyAction>` — Does something useful
````

---

## 26.13 Plugin Lifecycle: Unload and Reload

Plugins can be unloaded and reloaded at runtime. This is useful for hot-reloading during development or for dynamically swapping plugin implementations without restarting the application.

### Unloading a Plugin

When a plugin is unloaded, all actions and qualifiers it registered are automatically removed from their respective registries:

```swift
// Unload a plugin by name
let wasLoaded = UnifiedPluginLoader.shared.unload(pluginName: "my-plugin")
// Returns false if the plugin was not loaded
```

Unloading a plugin:
- Removes all dynamic action verbs the plugin registered from `ActionRegistry`
- Removes all qualifiers the plugin registered from `QualifierRegistry`
- Closes the native library handle (`dlclose`) for C/Rust plugins
- Is a no-op if the plugin is not currently loaded

### Reloading a Plugin

```swift
// Reload a plugin (unload + load from the same directory)
try UnifiedPluginLoader.shared.reload(pluginName: "my-plugin")
// Throws UnifiedPluginError.notFound if plugin was never loaded
```

Reloading re-reads the plugin from disk, which picks up any changes made to the plugin binary or source files.

### Error Handling

```swift
do {
    try UnifiedPluginLoader.shared.reload(pluginName: "csv-processor")
} catch UnifiedPluginError.notFound(let name) {
    print("Plugin '\(name)' was not previously loaded")
}
```

### Action Registry Tracking

When a plugin registers actions, the registry tracks which plugin each action belongs to:

```swift
// Actions registered with pluginName are tracked for bulk removal
await ActionRegistry.shared.registerDynamic(
    verb: "parse-csv",
    handler: myHandler,
    pluginName: "csv-processor"
)

// Remove all verbs registered by this plugin at once
await ActionRegistry.shared.unregisterPlugin("csv-processor")
```

Actions registered without a `pluginName` are not tracked and survive `unregisterPlugin` calls.

---

## 26.14 Example Plugins

The ARO team maintains several reference plugins:

| Plugin | Language | Purpose |
|--------|----------|---------|
| [plugin-swift-hello](https://github.com/arolang/plugin-swift-hello) | Swift | Greeting actions |
| [plugin-rust-csv](https://github.com/arolang/plugin-rust-csv) | Rust | CSV parsing |
| [plugin-c-hash](https://github.com/arolang/plugin-c-hash) | C | Hash functions |
| [plugin-python-markdown](https://github.com/arolang/plugin-python-markdown) | Python | Markdown processing |

---

*Next: Chapter 27 — Native Compilation*
