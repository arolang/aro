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
| **Actions** | New verbs | `<Verb> the <result> from <object>.` | `<Geocode> the <coords> from <address>.` |
| **Services** | External integrations | `<Call> from <service: method>` | `<Call> from <zip: compress>` |
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
    <Extract> the <text> from the <input: text>.
    <Transform> the <title> from <text> using <titlecase>.
    <Return> an <OK: status> with <title>.
}

(* TruncateText — Shorten text with ellipsis *)
(TruncateText: String Operations) {
    <Extract> the <text> from the <input: text>.
    <Extract> the <max-length> from the <input: maxLength>.
    <Compute> the <length: length> from <text>.
    when <length> > <max-length> {
        <Transform> the <truncated> from <text> using <substring: 0> to <max-length>.
        <Create> the <result> with <truncated> + "...".
    } else {
        <Create> the <result> with <text>.
    }
    <Return> an <OK: status> with <result>.
}
```

Feature sets from plugins are automatically available in your application with a qualified name:

```aro
(* Use plugin feature set *)
(Format User Name: User Processing) {
    <Extract> the <name> from the <user: fullName>.
    <Emit> a <FormatTitle: event> with { text: <name> }.
    <Return> an <OK: status> with <name>.
}
```

---

## 22.5 Swift Plugins

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
<Geocode> the <coordinates> from the <address>.
```

---

## 22.6 Native Plugins (Rust/C)

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

## 22.7 Python Plugins

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

## 22.8 Plugin Dependencies

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

## 22.9 Choosing a Plugin Type

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

## 22.10 Publishing Plugins

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

## 22.11 Example Plugins

The ARO team maintains several example plugins:

| Plugin | Language | Purpose |
|--------|----------|---------|
| [plugin-swift-hello](https://github.com/arolang/plugin-swift-hello) | Swift | Greeting actions |
| [plugin-rust-csv](https://github.com/arolang/plugin-rust-csv) | Rust | CSV parsing |
| [plugin-c-hash](https://github.com/arolang/plugin-c-hash) | C | Hash functions |
| [plugin-python-markdown](https://github.com/arolang/plugin-python-markdown) | Python | Markdown processing |

---

*Next: Chapter 23 — Native Compilation*
