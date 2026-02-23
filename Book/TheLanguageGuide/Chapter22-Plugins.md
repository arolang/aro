# Chapter 22: Plugins

*"Package and share your extensions."*

---

## 22.1 What Are Plugins?

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

## 22.2 Package Manager

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

## 22.3 Plugin Structure

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
| `handler` | No | Qualifier namespace prefix |
| `build` | No | Build configuration (for compiled plugins) |
| `python` | No | Python configuration (for python-plugin) |

The `handler` field defines the **qualifier namespace** for plugin-provided qualifiers. When set, qualifiers from this plugin are accessed as `handler.qualifier` in ARO code. If omitted, the plugin name is used as the namespace.

**Example:**

```yaml
provides:
  - type: swift-plugin
    path: Sources/
    handler: math      # Qualifiers accessed as <value: math.round>, <value: math.abs>
```

See section 22.5 for complete documentation on plugin qualifiers.

---

## 22.4 ARO File Plugins

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
    Transform the <title> from <text> using <titlecase>.
    Return an <OK: status> with <title>.
}

(* TruncateText — Shorten text with ellipsis *)
(TruncateText: String Operations) {
    Extract the <text> from the <input: text>.
    Extract the <max-length> from the <input: maxLength>.
    Compute the <length: length> from <text>.
    when <length> > <max-length> {
        Transform the <truncated> from <text> using <substring: 0> to <max-length>.
        Create the <result> with <truncated> + "...".
    } else {
        Create the <result> with <text>.
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

## 22.5 Plugin Qualifiers

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

### The Handler Namespace

Each plugin that provides qualifiers must declare a `handler:` field in its `provides:` entry. This becomes the **namespace prefix** for all qualifiers from that plugin.

```yaml
# plugin.yaml
name: plugin-swift-collection
version: 1.0.0
provides:
  - type: swift-plugin
    path: Sources/
    handler: collections    # Namespace for all qualifiers from this plugin
```

In ARO code, qualifiers are accessed as `handler.qualifier`:

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
provides:
  - type: c-plugin
    path: src/
    handler: list     # qualifiers accessed as list.first, list.last, list.size
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
provides:
  - type: python-plugin
    path: src/
    handler: stats    # qualifiers accessed as stats.sort, stats.min, etc.
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

## 22.6 Swift Plugins

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

## 22.7 Native Plugins (Rust/C)

Native plugins use a C ABI interface for high-performance operations.

### Required C Interface

```c
// Get plugin info as JSON
char* aro_plugin_info(void);

// Execute an action
char* aro_plugin_execute(const char* action, const char* input_json);

// Free memory
void aro_plugin_free(char* ptr);
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

#[no_mangle]
pub extern "C" fn aro_plugin_info() -> *mut c_char {
    let info = r#"{"name":"plugin-rust-csv","version":"1.0.0","actions":["parse-csv"]}"#;
    CString::new(info).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn aro_plugin_execute(
    action: *const c_char,
    input_json: *const c_char,
) -> *mut c_char {
    // Parse action and input, execute, return JSON result
    let result = r#"{"rows": [], "count": 0}"#;
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

char* aro_plugin_info(void) {
    const char* info = "{\"name\":\"plugin-c-hash\",\"actions\":[\"hash\"]}";
    char* result = malloc(strlen(info) + 1);
    strcpy(result, info);
    return result;
}

char* aro_plugin_execute(const char* action, const char* input) {
    // Implementation
    char* result = malloc(256);
    snprintf(result, 256, "{\"hash\":\"abc123\"}");
    return result;
}

void aro_plugin_free(char* ptr) {
    if (ptr) free(ptr);
}
```

---

## 22.8 Python Plugins

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

## 22.9 Plugin Dependencies

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

## 22.10 Choosing a Plugin Type

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

## 22.11 Publishing Plugins

1. Create a Git repository with `plugin.yaml`
2. Tag releases following semantic versioning
3. Document installation in README
4. Publish to GitHub (or any Git host)

**Example README:**

```markdown
# my-plugin

Install:
\`\`\`bash
aro add git@github.com:yourname/my-plugin.git
\`\`\`

## Actions

- `<MyAction>` — Does something useful
```

---

## 22.12 Example Plugins

The ARO team maintains several example plugins:

| Plugin | Language | Purpose |
|--------|----------|---------|
| [plugin-swift-hello](https://github.com/arolang/plugin-swift-hello) | Swift | Greeting actions |
| [plugin-rust-csv](https://github.com/arolang/plugin-rust-csv) | Rust | CSV parsing |
| [plugin-c-hash](https://github.com/arolang/plugin-c-hash) | C | Hash functions |
| [plugin-python-markdown](https://github.com/arolang/plugin-python-markdown) | Python | Markdown processing |

---

*Next: Chapter 23 — Native Compilation*
