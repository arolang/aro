# Proposal: Package Manager & Extended Plugin System

**Proposal-ID:** ARO-0045
**Author:** ARO Language Team
**Status:** Draft
**Created:** 2026-02-11
**Branch:** `features/package-manager`
**Requires:** Core Runtime, Plugin System (existing)

---

## Summary

This proposal describes the introduction of an integrated package manager for ARO that enables adding external packages via Git repositories, automatically checking them out into the local `Plugins/` directory, and seamlessly integrating them into the existing plugin system.

**Core Principle: The `Plugins/` directory is the Single Source of Truth.** There is no lockfile. Instead, every plugin must have a `plugin.yaml` in its root that contains all relevant information about the plugin. At startup, ARO simply scans the `Plugins/` directory, reads each `plugin.yaml`, and registers the plugins accordingly. This keeps the system simple, transparent, and traceable.

Additionally, the plugin system is extended to support both `.aro` files (declarative project files) and native Swift plugin sources in a single repository. Finally, we evaluate whether and how plugins can be written in other languages (Rust, C++, Python) and provided in ARO.

---

## Motivation

### Status Quo

Currently, ARO has a plugin system that supports Swift-based plugins. These are manually integrated into the project. There is no standardized way to obtain, version, or manage plugins or extension packages from external sources.

### Problems

1. **No central package mechanism:** Developers must manually copy, clone, and configure plugins. This leads to inconsistencies and version conflicts.
2. **Limited plugin type:** The current system only recognizes Swift source code as plugins. `.aro` files in a repository are ignored, even though they could serve as declarative extensions (e.g., additional feature sets, actions, templates).
3. **No multi-language support:** The restriction to Swift prevents the community from contributing plugins in languages that are better suited for certain domains (e.g., Rust for performance-critical processing, C++ for system-level integrations, Python for data science and scripting).

### Goal

A simple, Git-based package mechanism following the principle:

```bash
aro add git@git.ausdertechnik.de:packages/aro-packages-additionaltools.git
```

This command should clone the repository, check it out into `Plugins/`, and automatically detect and register all contained plugin types.

---

## Proposed Solution

### 1. The `aro add` Command

#### Syntax

```bash
# Add Git repository (SSH)
aro add git@git.ausdertechnik.de:packages/aro-packages-additionaltools.git

# Add Git repository (HTTPS)
aro add https://git.ausdertechnik.de/packages/aro-packages-additionaltools.git

# Specific version / tag / branch
aro add git@git.ausdertechnik.de:packages/aro-packages-additionaltools.git --ref v1.2.0
aro add git@git.ausdertechnik.de:packages/aro-packages-additionaltools.git --branch develop

# Remove plugin
aro remove aro-packages-additionaltools

# List installed plugins
aro plugins list

# Update plugins
aro plugins update
aro plugins update aro-packages-additionaltools
```

#### Detailed Process

```
aro add git@git.ausdertechnik.de:packages/aro-packages-additionaltools.git
```

**Step 1: Clone Repository**

```
1. Parse the Git URL
2. Extract the package name from the URL (e.g., "aro-packages-additionaltools")
3. Check if the package already exists in Plugins/
   → If yes: Update (git pull) or error on version conflicts
   → If no: Continue with step 4
4. Clone the repository into a temporary directory
5. Checkout the desired ref (Default: main/master)
```

**Step 2: Validate plugin.yaml**

```
6. Search for plugin.yaml in the repository root
7. If present: Read metadata (name, version, dependencies, type)
8. If NOT present: Abort with error — plugin.yaml is mandatory
9. Validate dependencies and check compatibility
```

**Step 3: Check out into Plugins/**

```
10. Copy files to Plugins/<packagename>/
    (plugin.yaml is part of the repository and is copied along)
11. Execute build steps if necessary (e.g., Swift compilation)
12. Confirm installation with summary
```

#### Example Output

```
$ aro add git@git.ausdertechnik.de:packages/aro-packages-additionaltools.git

📦 Resolving package: aro-packages-additionaltools
   Cloning from git@git.ausdertechnik.de:packages/aro-packages-additionaltools.git...
   ✓ Cloned (ref: main, commit: a3f8c21)

📂 Reading plugin.yaml:
   Name:    aro-packages-additionaltools
   Version: 1.0.0
   Found 3 .aro files (project files)
   Found 2 Swift plugin sources

🔗 Installing to Plugins/aro-packages-additionaltools/
   ✓ Registered 3 ARO feature sets
   ✓ Compiled 2 Swift plugins

✅ Package "aro-packages-additionaltools" v1.0.0 installed successfully.
   Available actions: <FormatCSV>, <ValidateXML>, <TransformJSON>
```

---

### 2. Plugin Manifest: `plugin.yaml` (mandatory)

Every plugin **must** have a `plugin.yaml` in its root directory. This file is the only source for metadata about the plugin. Without `plugin.yaml`, a directory in `Plugins/` is not recognized as a plugin.

```yaml
name: aro-packages-additionaltools
version: 1.0.0
description: "Additional tools and actions for ARO projects"
author: "Aus der Technik"
license: MIT
aro-version: ">=0.1.0"

# Origin — automatically set by `aro add`
source:
  git: "git@git.ausdertechnik.de:packages/aro-packages-additionaltools.git"
  ref: "main"
  commit: "a3f8c21e4b5d6f7890abcdef1234567890abcdef"

# What content this plugin provides
provides:
  - type: aro-files          # .aro Feature Sets
    path: features/
  - type: swift-plugin        # Swift Plugin Sources
    path: Sources/
    handler: tools            # Qualifier namespace: <value: tools.qualifier>
  - type: aro-templates       # Templates
    path: templates/

# Dependencies on other ARO plugins
dependencies:
  aro-core-utils:
    git: "git@git.ausdertechnik.de:packages/aro-core-utils.git"
    ref: "v2.0.0"

# Build configuration (optional)
build:
  swift:
    minimum-version: "6.2"
    targets:
      - name: AdditionalTools
        path: Sources/
```

#### Why is `plugin.yaml` mandatory?

The `Plugins/` directory is read directly — there is no separate lockfile or central registry file. For this to work, each plugin must describe itself:

1. **Identification:** `name` and `version` uniquely identify the plugin.
2. **Origin:** The `source` field documents where the plugin came from (automatically populated by `aro add`). Local plugins without Git origin leave this field empty.
3. **Discovery:** The `provides` field tells ARO which file types are located where — no guessing, no recursive scanning needed.
4. **Dependencies:** The `dependencies` field enables ARO to detect and report missing dependencies at startup.

#### Runtime Discovery: How ARO Detects Plugins

At startup, ARO executes the following algorithm:

```
1. Scan Plugins/ directory (one level deep)
2. For each subdirectory:
   a. Search for plugin.yaml
   b. If not present → Issue warning, ignore directory
   c. If present → Parse plugin.yaml
   d. Validate required fields (name, version, provides)
   e. Register plugin in PluginRegistry
3. Check dependencies of all plugins against each other
4. Load plugins in topological order (dependencies first)
```

This approach has several advantages over a lockfile:

- **Transparency:** `ls Plugins/` immediately shows what is installed.
- **No sync problem:** Lockfile and actual state can never diverge.
- **Manual installation:** A plugin can simply be placed in `Plugins/` via `git clone` or copying — as long as a `plugin.yaml` is present, it will be recognized.
- **Easy debugging:** `cat Plugins/myplugin/plugin.yaml` shows all information.

#### `aro plugins list` — Directory as Source

```
$ aro plugins list

Installed Plugins (from Plugins/):
───────────────────────────────────────────────────────────────────
 Name                             Version  Source                   Provides
 aro-packages-additionaltools     1.0.0    git@git...tools.git      3 .aro, 2 swift
 aro-core-utils                   2.0.0    git@git...utils.git      5 .aro, 1 swift
 my-local-plugin                  0.1.0    (local)                  1 swift
───────────────────────────────────────────────────────────────────
 3 plugins loaded, 0 warnings
```

All information comes exclusively from the `plugin.yaml` files of the individual directories.

---

### 3. Extended Plugin System: Dual-Mode Plugins

#### Current Architecture

```
Plugins/
└── MyPlugin/
    └── Sources/
        └── MyPlugin.swift      ← Swift only
```

#### New Architecture: Hybrid Plugins

```
Plugins/
└── aro-packages-additionaltools/
    ├── plugin.yaml                    ← Plugin manifest (mandatory)
    │
    ├── features/                      ← ARO Feature Sets (.aro files)
    │   ├── csv-processing.aro
    │   ├── xml-validation.aro
    │   └── json-transform.aro
    │
    ├── Sources/                       ← Swift Plugin Sources
    │   ├── CSVFormatter.swift
    │   └── XMLValidator.swift
    │
    └── tests/                         ← Tests
        ├── csv-processing.test.aro
        └── CSVFormatterTests.swift
```

#### How .aro Files Work as Plugins

`.aro` files in a package are treated as **declarative extensions**. They can:

1. **Provide new feature sets** that are automatically imported into the project:

```aro
(* csv-processing.aro — Provided by aro-packages-additionaltools *)

(FormatCSV: Data Processing) {
    Extract the <raw-data> from the <input: data>.
    Parse the <raw-data> as <CSV: format>.
    Transform each <row> in the <parsed-data> with <column-mapping>.
    Return the <formatted-output> as <CSV: string>.
}

(ValidateCSVSchema: Data Validation) {
    Extract the <csv-data> from the <input: data>.
    Extract the <schema> from the <input: schema>.
    Validate the <csv-data> against the <schema>.
    When the <validation: failed> Then {
        Throw a <ValidationError: error> for the <validation: errors>.
    }.
    Return a <Valid: status>.
}
```

2. **Define new actions** that can be used by other `.aro` files:

```aro
(* Defines a reusable action *)
(Define Action: FormatCSV) {
    Accept the <data: string> as <input>.
    Accept the <delimiter: string> as <option> with default ",".
    <Produce> the <formatted: string> as <output>.
}
```

3. **Provide templates and patterns** for common use cases.

#### Plugin Loading Order

```
1. ARO Compiler starts
2. Scan Plugins/ directory (one level deep)
3. For each subdirectory:
   a. Read plugin.yaml (mandatory — without it, the directory is ignored)
   b. Read provides entries and load accordingly:
      - type: aro-files → Parse and register feature sets
      - type: swift-plugin → Compile and load as native plugins
      - type: c-plugin / rust-plugin → Load via FFI with handler namespace
      - type: python-plugin → Load as subprocess with handler namespace
      - handler field → Register qualifiers as handler.qualifier in QualifierRegistry
   c. Link ARO actions with Swift implementations
4. Make all plugins available in the global ActionRegistry
```

#### Import in Projects

After a package is installed, its feature sets can be used in your own `.aro` files:

```aro
(* Own project: main.aro *)
(* Uses actions from the installed package *)

(processReport: Report API) {
    Extract the <file> from the <request: body>.
    <FormatCSV> the <file> with { delimiter: ";", encoding: "UTF-8" }.
    <ValidateCSVSchema> the <formatted-file> against <report-schema>.
    Store the <validated-report> into the <report-repository>.
    Return a <Created: status> with <validated-report>.
}
```

#### Plugin Qualifier Namespacing

Plugins that provide qualifiers must declare a `handler:` field in their `provides:` entry. The handler name becomes the **namespace prefix** for all qualifiers from that plugin in ARO code:

```yaml
# plugin.yaml
provides:
  - type: c-plugin
    path: src/
    handler: list          # qualifiers: list.first, list.last, list.size
```

```aro
(* Usage in ARO code *)
Compute the <first-element: list.first> from the <numbers>.
Log <numbers: list.last> to the <console>.
```

Qualifier registration in the plugin's C/Swift/Python code uses **plain names** (without namespace):

```c
// aro_plugin_info() returns qualifiers with plain names
{"qualifiers": [{"name": "first"}, {"name": "last"}, {"name": "size"}]}

// aro_plugin_qualifier() receives plain name
char* aro_plugin_qualifier(const char* qualifier_name, const char* input_json) {
    // qualifier_name = "first" (not "list.first")
}
```

The `handler:` prefix serves as a disambiguation mechanism when multiple plugins provide qualifiers with identical names (e.g., two plugins both providing `sort`).

---

### 4. Design Decision: No Lockfile

Deliberately, a central lockfile (`aro-packages.lock` or similar) is not used. The reasons:

| Lockfile Approach | Directory Approach (chosen) |
|-------------------|------------------------------|
| Central file can desynchronize from reality | `Plugins/` **is** the reality |
| Merge conflicts in lockfile during teamwork | No central file = no conflicts |
| Requires `aro install` after `git pull` | Plugin is already in the directory |
| Additional abstraction | Simple: `ls Plugins/` shows everything |

Instead, each plugin carries its entire identity in its own `plugin.yaml`. The `source` field documents the origin (Git URL, ref, commit), so `aro plugins update` knows where a plugin came from and how it can be updated.

Reproducible builds are ensured by committing the entire `Plugins/` directory to the project repository — or alternatively via a `.aro-sources` file (list of Git URLs) that enables an `aro plugins restore`:

---

### 5. Project Structure After Integration

```
MyAroProject/
├── main.aro                          ← Own project
├── openapi.yaml
├── Plugins/                          ← Single Source of Truth
│   ├── aro-packages-additionaltools/ ← Installed via `aro add`
│   │   ├── plugin.yaml              ← Mandatory — describes the plugin
│   │   ├── features/
│   │   │   ├── csv-processing.aro
│   │   │   └── xml-validation.aro
│   │   └── Sources/
│   │       ├── CSVFormatter.swift
│   │       └── XMLValidator.swift
│   ├── aro-core-utils/               ← Dependency, also via `aro add`
│   │   ├── plugin.yaml
│   │   └── Sources/
│   │       └── CoreUtils.swift
│   └── my-local-plugin/              ← Own, local plugin
│       ├── plugin.yaml              ← Local plugins also need this
│       └── Sources/
│           └── MyPlugin.swift
└── .gitignore
```

**Note:** There is no `.aro-cache/` and no lockfile. The `Plugins/` directory can either be committed completely (for full reproducibility) or excluded via `.gitignore` if relying on `aro add` + the `source` entries in the `plugin.yaml` files.

---

### 6. Evaluation: Plugins in Other Languages

#### Question

Can ARO plugins also be written in Rust, C++, Python, or other languages and be made available in the ARO runtime?

#### Analysis

##### 6.1 Rust Plugins

**Feasibility: ✅ High**

Rust offers an excellent foundation for integration with Swift through its C-ABI-compatible Foreign Function Interface (FFI):

```
Rust Plugin (.rs)
       │
       ▼
  cargo build → libplugin.dylib / .so
       │
       ▼
  Swift FFI (via C header)
       │
       ▼
  ARO ActionRegistry
```

**Advantages:**
- Memory safety without garbage collector — fits the ARO philosophy
- Excellent performance for data-intensive operations
- `cbindgen` automatically generates C headers from Rust code
- No runtime dependency (statically linkable)

**Implementation Approach:**

```rust
// Rust: plugins/src/lib.rs
#[no_mangle]
pub extern "C" fn aro_action_format_csv(
    input: *const c_char,
    delimiter: *const c_char,
) -> *mut c_char {
    let input = unsafe { CStr::from_ptr(input).to_str().unwrap() };
    let delimiter = unsafe { CStr::from_ptr(delimiter).to_str().unwrap() };
    // Processing...
    CString::new(result).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn aro_plugin_manifest() -> *const c_char {
    // Returns plugin metadata as JSON
    CString::new(r#"{"name":"csv-formatter","version":"1.0","actions":["FormatCSV"]}"#)
        .unwrap().into_raw()
}
```

```yaml
# plugin.yaml for a Rust plugin
name: csv-formatter-rs
version: 1.0.0
description: "High-performance CSV formatter in Rust"
author: "Community"
aro-version: ">=0.2.0"

provides:
  - type: rust-plugin
    path: src/
    build:
      cargo-target: release
      output: libcsvformatter.dylib
```

**Effort:** Medium — Requires a plugin FFI protocol and build integration for Cargo.

##### 6.2 C/C++ Plugins

**Feasibility: ✅ High**

C and C++ can be directly integrated via Swift's C interoperability:

```
C/C++ Plugin (.c / .cpp)
       │
       ▼
  Compiler → libplugin.dylib / .so
       │
       ▼
  Swift direct import (Bridging Header / modulemap)
       │
       ▼
  ARO ActionRegistry
```

**Advantages:**
- Most direct integration — Swift can natively import C
- Maximum performance
- Access to extensive existing C/C++ libraries
- No additional build tool needed (clang is sufficient)

**Implementation Approach:**

```c
// C: plugins/xml_validator.h
#ifndef ARO_XML_VALIDATOR_H
#define ARO_XML_VALIDATOR_H

typedef struct {
    const char* name;
    const char* version;
    const char** actions;
    int action_count;
} AroPluginManifest;

AroPluginManifest aro_plugin_manifest(void);
const char* aro_action_validate_xml(const char* input, const char* schema);

#endif
```

```yaml
# plugin.yaml for a C plugin
name: xml-validator-c
version: 1.0.0
description: "XML validator using libxml2"
aro-version: ">=0.2.0"

provides:
  - type: c-plugin
    path: src/
    build:
      compiler: clang
      flags: ["-O2", "-shared"]
      output: libxmlvalidator.dylib
```

**Effort:** Low — Swift's C interop makes this the easiest integration path.

##### 6.3 Python Plugins (via PythonKit)

**Feasibility: ✅ High**

Swift can directly call Python code via [PythonKit](https://github.com/pvieito/PythonKit) — without FFI detour, without intermediate layer. PythonKit provides a native Swift bridge to the CPython runtime and enables access to the entire Python ecosystem:

```
Python Plugin (.py)
       │
       ▼
  PythonKit (Swift ↔ Python Bridge)
       │
       ▼
  ARO PluginHost
       │
       ▼
  ARO ActionRegistry
```

**Advantages:**
- Access to the entire Python ecosystem (NumPy, Pandas, scikit-learn, Requests, etc.)
- Ideal for data science, ML inference, scripting, and prototyping
- No compilation step needed for plugin code — Python files are interpreted directly
- PythonKit is a pure Swift package, easy to integrate
- Hot-reload possible: Python plugins can be reloaded at runtime

**Implementation Approach:**

```python
# Python: plugins/data_analyzer.py

def aro_plugin_info():
    return {
        "name": "data-analyzer",
        "version": "1.0.0",
        "language": "python",
        "actions": ["AnalyzeCSV", "TrainModel", "PredictValue"]
    }

def aro_action_analyze_csv(input_json):
    import json
    import pandas as pd

    params = json.loads(input_json)
    df = pd.read_csv(params["file_path"])

    result = {
        "rows": len(df),
        "columns": list(df.columns),
        "summary": df.describe().to_dict()
    }
    return json.dumps(result)

def aro_action_train_model(input_json):
    import json
    from sklearn.linear_model import LinearRegression

    params = json.loads(input_json)
    # Train model...
    return json.dumps({"status": "trained", "accuracy": 0.95})
```

**Swift-side Integration via PythonKit:**

```swift
// PythonPluginHost.swift
import PythonKit

struct PythonPluginHost {
    let sys = Python.import("sys")
    let json = Python.import("json")

    func loadPlugin(at path: String) -> AroPluginInfo {
        sys.path.append(path)
        let module = Python.import("data_analyzer")
        let info = module.aro_plugin_info()
        // PythonKit automatically converts Python dicts
        return AroPluginInfo(from: info)
    }

    func execute(action: String, input: String) -> String {
        let module = Python.import("data_analyzer")
        let funcName = "aro_action_\(action.lowercased())"
        let result = module[dynamicMember: funcName](input)
        return String(result) ?? "{}"
    }
}
```

```yaml
# plugin.yaml for a Python plugin
name: data-analyzer
version: 1.0.0
description: "Data analysis and ML inference via Python"
author: "Community"
aro-version: ">=0.2.0"

provides:
  - type: python-plugin
    path: src/
    python:
      min-version: "3.9"
      requirements: requirements.txt   # pip dependencies
```

**Limitations:**
- Requires an installed Python runtime on the target system
- GIL (Global Interpreter Lock) limits true parallelism
- Startup overhead on first Python import (~100-200ms)

**Effort:** Low to medium — PythonKit handles the heavy lifting of the bridge. Main effort lies in the `PythonPluginHost` and `requirements.txt` management.

##### 6.4 Overview and Recommendation

| Language | Feasibility | Effort | Performance | Dependencies | Recommendation |
|----------|------------|--------|-------------|--------------|----------------|
| **Swift** | ✅ Native | Low | Excellent | None | Standard (already implemented) |
| **Rust** | ✅ High | Medium | Excellent | Cargo (build-time) | **Phase 2: Recommended** |
| **C/C++** | ✅ High | Low | Excellent | Compiler (build-time) | **Phase 2: Recommended** |
| **Python** | ✅ High | Low-Medium | Moderate | Python Runtime + PythonKit | **Phase 2: Recommended** |
| Go | ✅ High | Medium | Very good | Go (build-time) | Evaluate in future |
| Java | ⚠️ Medium | High | Good | JVM or GraalVM | Evaluate in future |

**Recommended Roadmap:**

1. **Phase 1 (this proposal):** Swift plugins + `.aro` files as dual-mode
2. **Phase 2:** C/C++ and Rust via FFI protocol, Python via PythonKit
3. **Phase 3:** Additional languages based on community demand

#### 6.5 Universal Plugin FFI Protocol

To enable multi-language plugins, a language-agnostic C-ABI protocol is defined:

```c
// aro_plugin_protocol.h — The universal plugin interface

#define ARO_PLUGIN_API_VERSION 1

typedef struct {
    int api_version;
    const char* name;
    const char* version;
    const char* language;           // "swift", "rust", "c", "cpp", "python"
    const char* description;
} AroPluginInfo;

typedef struct {
    const char* name;
    const char* input_schema;       // JSON Schema for input
    const char* output_schema;      // JSON Schema for output
} AroActionDescriptor;

// Every plugin must export these functions:
AroPluginInfo           aro_plugin_info(void);
int                     aro_plugin_action_count(void);
AroActionDescriptor     aro_plugin_action_at(int index);
const char*             aro_plugin_execute(const char* action_name, const char* input_json);
void                    aro_plugin_free(const char* ptr);
```

This protocol enables writing plugins in any language that can produce C-compatible shared libraries.

---

## Implementation Project Structure

The following files and modules must be created or extended:

```
Sources/
├── AROCLI/
│   └── Commands/
│       ├── AddCommand.swift          ← NEW: "aro add" command
│       ├── RemoveCommand.swift       ← NEW: "aro remove" command
│       └── PluginsCommand.swift      ← NEW: "aro plugins" command
│
├── AROPackageManager/                ← NEW: Entire module
│   ├── PackageManager.swift          ← Main logic
│   ├── GitClient.swift               ← Git operations (clone, pull, checkout)
│   ├── PluginManifest.swift          ← plugin.yaml parser & validator
│   ├── PluginScanner.swift           ← Scans Plugins/ and reads plugin.yaml files
│   ├── DependencyResolver.swift      ← Dependency resolution via plugin.yaml
│   └── PluginInstaller.swift         ← Installation into Plugins/
│
├── ARORuntime/
│   ├── Plugins/
│   │   ├── PluginLoader.swift        ← EXTEND: Dual-mode loading via plugin.yaml
│   │   ├── AroFilePlugin.swift       ← NEW: .aro files as plugins
│   │   ├── SwiftPluginHost.swift     ← EXISTING: Adapt
│   │   ├── NativePluginHost.swift    ← NEW: C/Rust FFI Host (Phase 2)
│   │   ├── PythonPluginHost.swift    ← NEW: Python via PythonKit (Phase 2)
│   │   └── PluginProtocol.swift      ← EXTEND: Universal protocol
│   └── Actions/
│       └── ActionRegistry.swift      ← EXTEND: Register plugin actions
│
└── Tests/
    ├── PackageManagerTests/
    │   ├── AddCommandTests.swift
    │   ├── PluginManifestTests.swift
    │   └── PluginScannerTests.swift
    └── PluginTests/
        ├── AroFilePluginTests.swift
        └── DualModePluginTests.swift
```

---

## Open Questions

1. **Conflict Resolution:** What happens when two plugins define an action with the same name? Proposal: Namespace prefix (`pluginname.ActionName`) or explicit error message.

2. **Private Repositories:** Should `aro add` automatically pass through SSH keys and token-based authentication? Or should it rely on the system Git configuration?

3. **Commit plugins or not?** Should the `Plugins/` directory be committed by default (vendoring style) or excluded via `.gitignore`? Both should be supported, but what is the recommended default?

4. **Version Strategy:** Enforce Semantic Versioning (SemVer) or allow arbitrary Git refs?

5. **Plugin Sandboxing:** Should plugins (especially native C/Rust) run in a sandbox to minimize security risks?

6. **Central Registry:** Should a central package registry (similar to npm, crates.io) be built long-term for ARO packages, or should it remain Git URLs only?

7. **Minimal `plugin.yaml`:** Which fields are true required fields? Proposal: only `name`, `version`, and `provides`. Everything else optional.

---

## Backwards Compatibility

This proposal is **fully backwards compatible**:

- Existing Swift plugins in `Plugins/` continue to work, **but must be supplemented with a `plugin.yaml`.** Without `plugin.yaml`, a warning is issued; during a transition period (until v0.3.0), such plugins are still loaded.
- The `aro add` command is optional — manual plugin installation remains possible as long as a `plugin.yaml` is present.
- `.aro` files in plugin directories are only recognized when the new PluginLoader is active.
- No lockfile is created or required.

---

## Implementation Plan

| Phase | Scope | Estimated Effort |
|-------|-------|------------------|
| **Phase 1a** | `plugin.yaml` schema + parser + validator | 1 week |
| **Phase 1b** | PluginScanner — read `Plugins/` via `plugin.yaml` | 1 week |
| **Phase 1c** | `aro add` — Git clone & checkout to Plugins/ | 1-2 weeks |
| **Phase 1d** | Dual-mode PluginLoader (.aro + .swift) | 1-2 weeks |
| **Phase 1e** | `aro remove` + `aro plugins list/update` | 1 week |
| **Phase 2a** | FFI protocol + C/Rust Plugin Host | 2-3 weeks |
| **Phase 2b** | Python Plugin Host via PythonKit | 1-2 weeks |
| **Phase 3** | Additional languages based on community demand | TBD |

---

## References

- [Swift Package Manager — Dependency Resolution](https://github.com/apple/swift-package-manager/blob/main/Documentation/PackageDescription.md)
- [Cargo — The Rust Package Manager](https://doc.rust-lang.org/cargo/)
- [cbindgen — Generating C bindings from Rust](https://github.com/mozilla/cbindgen)
- [PythonKit — Swift ↔ Python Bridge](https://github.com/pvieito/PythonKit)
- [ARO Language Tutorial](https://krissimon.github.io/aro/tutorial.html)
- Existing ARO Proposals: ARO-0001 to ARO-0044

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-02-11 | Initial proposal |
| 1.1 | 2026-02-11 | Lockfile removed, `plugin.yaml` as mandatory manifest, directory-based discovery |
| 1.2 | 2026-02-11 | Java evaluation removed, Python plugins via PythonKit added |
