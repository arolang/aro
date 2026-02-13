# Appendix A: plugin.yaml Reference

This appendix provides a complete reference for the `plugin.yaml` manifest file format.

## Overview

The `plugin.yaml` file is the manifest that describes your plugin to ARO. It must be placed at the root of your plugin directory.

```yaml
name: my-plugin
version: 1.0.0
description: A description of what this plugin does
author: Your Name <your.email@example.com>
license: MIT

aro-version: ">=0.9.0"

source:
  git: https://github.com/username/my-plugin
  ref: v1.0.0

provides:
  - type: swift-plugin
    path: Sources/
    actions:
      - formatDate
      - formatCurrency

dependencies:
  some-other-plugin:
    git: https://github.com/other/plugin
    ref: v2.0.0
```

## Top-Level Fields

### name (required)

```yaml
name: my-plugin
```

The plugin identifier. Must be:
- Lowercase letters, numbers, and hyphens only
- Start with a letter
- Maximum 50 characters
- Unique within your namespace

### version (required)

```yaml
version: 1.2.3
```

The plugin version using [Semantic Versioning](https://semver.org/):
- `MAJOR.MINOR.PATCH`
- Pre-release: `1.0.0-alpha.1`, `1.0.0-beta.2`, `1.0.0-rc.1`
- Build metadata: `1.0.0+build.123`

### description

```yaml
description: Provides date, time, and currency formatting utilities
```

A brief description (recommended: one sentence, max 200 characters).

### author

```yaml
author: Jane Developer <jane@example.com>
```

Or multiple authors:

```yaml
authors:
  - Jane Developer <jane@example.com>
  - John Contributor <john@example.com>
```

### license

```yaml
license: MIT
```

SPDX license identifier. Common values:
- `MIT`
- `Apache-2.0`
- `GPL-3.0`
- `BSD-3-Clause`
- `ISC`
- `Unlicense`

### homepage

```yaml
homepage: https://my-plugin.example.com
```

URL to the plugin's homepage or documentation site.

### repository

```yaml
repository: https://github.com/username/my-plugin
```

URL to the source repository.

### keywords

```yaml
keywords:
  - formatting
  - dates
  - currency
  - localization
```

Tags for discoverability (max 10 keywords).

## ARO Compatibility

### aro-version

```yaml
aro-version: ">=0.9.0"
```

Specifies compatible ARO versions using npm-style version constraints:

| Pattern | Meaning |
|---------|---------|
| `>=0.9.0` | 0.9.0 or higher |
| `>=0.9.0 <1.0.0` | 0.9.x versions only |
| `^0.9.0` | Compatible with 0.9.x |
| `~0.9.0` | Approximately 0.9.x |
| `0.9.0 \|\| 1.0.0` | Either version |
| `*` | Any version |

## Source Information

### source

For plugins distributed via Git:

```yaml
source:
  git: https://github.com/username/my-plugin
  ref: v1.0.0
```

Or with SSH:

```yaml
source:
  git: git@github.com:username/my-plugin.git
  ref: main
```

Fields:
- `git`: Repository URL (required)
- `ref`: Git reference - tag, branch, or commit (recommended: use tags)
- `commit`: Specific commit SHA (for pinning)

## Provides Section

The `provides` array declares what your plugin offers.

### Swift Plugin

```yaml
provides:
  - type: swift-plugin
    path: Sources/MyPlugin/
    actions:
      - name: formatDate
        description: Format a date according to a pattern
      - name: formatCurrency
        description: Format a number as currency
```

Fields:
- `type`: `swift-plugin`
- `path`: Path to Swift sources (relative to plugin.yaml)
- `actions`: List of action definitions (see Action Specification below)

### Action Specification

Actions can be declared with full metadata for native ARO integration:

```yaml
actions:
  # Simple form - service via <Call>
  - name: processData
    description: Process data

  # Full form - custom action verb
  - name: Hash
    role: own
    verbs: [hash, digest, checksum]
    prepositions: [from, with]
    description: Compute cryptographic hash
    arguments:
      algorithm:
        type: string
        default: sha256
        values: [sha256, sha512, md5]
      encoding:
        type: string
        default: hex
        values: [hex, base64]
```

**Action Fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Action identifier |
| `description` | No | Human-readable description |
| `role` | No | Semantic role: `request`, `own`, `response`, `export` |
| `verbs` | No | Verbs that trigger this action (enables `<Hash>` syntax) |
| `prepositions` | No | Valid prepositions for this action |
| `arguments` | No | Argument schema with types and defaults |

**Roles:**
- `request`: External → Internal (Extract, Retrieve, Fetch)
- `own`: Internal → Internal (Compute, Hash, Transform)
- `response`: Internal → External (Return, Send, Log)
- `export`: Makes data available (Publish, Store)

**Prepositions:**
- `from`: Data source
- `to`: Destination
- `with`: Parameters/options
- `for`: Purpose
- `into`: Container
- `as`: Type/format
- `against`: Comparison
- `via`: Method

When `verbs` is specified, the action registers as a native ARO verb:
```aro
(* With verbs: [hash, digest] - these work: *)
<Hash> the <result: sha256> from the <data>.
<Digest> the <checksum> from the <file>.

(* Without verbs - only via Call: *)
<Call> the <result> from the <plugin: processData> with { ... }.
```

### Rust Plugin

```yaml
provides:
  - type: rust-plugin
    path: src/
    build:
      cargo-target: cdylib
    actions:
      - validate
      - transform
```

Fields:
- `type`: `rust-plugin`
- `path`: Path to Cargo project
- `build`:
  - `cargo-target`: Library type (`cdylib` for dynamic library)
  - `features`: Optional Cargo features to enable
  - `profile`: Build profile (`release` or `debug`)

### C Plugin

```yaml
provides:
  - type: c-plugin
    path: src/
    build:
      compiler: clang
      flags:
        - "-O2"
        - "-Wall"
      include:
        - /opt/homebrew/include
      libs:
        - "-lz"
        - "-lpthread"
      output: libmyplugin
```

Fields:
- `type`: `c-plugin`
- `path`: Path to C sources
- `build`:
  - `compiler`: Compiler to use (`clang`, `gcc`)
  - `flags`: Compiler flags
  - `include`: Include directories
  - `libs`: Libraries to link
  - `output`: Output library name (without extension)

### C++ Plugin

```yaml
provides:
  - type: cpp-plugin
    path: src/
    build:
      compiler: clang++
      standard: c++17
      flags:
        - "-O2"
        - "-Wall"
      libs:
        - "-lstdc++"
```

Fields:
- `type`: `cpp-plugin`
- Same as C plugin, plus:
  - `standard`: C++ standard (`c++11`, `c++14`, `c++17`, `c++20`)

### Python Plugin

```yaml
provides:
  - type: python-plugin
    path: src/
    python:
      min-version: "3.9"
      requirements: requirements.txt
    actions:
      - generate
      - summarize
```

Fields:
- `type`: `python-plugin`
- `path`: Path to Python sources
- `python`:
  - `min-version`: Minimum Python version
  - `requirements`: Path to requirements.txt
  - `venv`: Virtual environment path (optional)

### ARO Files

```yaml
provides:
  - type: aro-files
    path: features/
```

Fields:
- `type`: `aro-files`
- `path`: Path to directory containing `.aro` files

Feature sets from ARO files are registered with the runtime:
- **Event Handlers**: Feature sets with business activity `<EventName> Handler` become automatic event handlers
- **Reusable Feature Sets**: Other feature sets are available for invocation

Example event handler:
```aro
(* Automatically handles UserCreated events *)
(Log User Events: UserCreated Handler) {
    <Log> "[AUDIT] User created" to the <console>.
    <Return> an <OK: status> for the <audit>.
}
```

A plugin with only `aro-files` providers (no native code) is called a **pure ARO plugin**.

### System Objects

```yaml
provides:
  - type: rust-plugin
    path: src/
    system-objects:
      - name: redis
        capabilities: [readable, writable, enumerable]
        config:
          connection-url: REDIS_URL
          default-url: "redis://127.0.0.1:6379"
```

Fields:
- `system-objects`: Array of system object definitions
  - `name`: Object identifier (used as `<redis: ...>`)
  - `capabilities`: Array of supported operations
    - `readable`: Supports `<Read>`, `<Get>`, `<Extract>`
    - `writable`: Supports `<Write>`, `<Send>`
    - `enumerable`: Supports `<List>`
    - `watchable`: Supports `<Watch>`
  - `config`: Configuration options
    - Key-value pairs where value is environment variable name or default

## Dependencies

### dependencies

```yaml
dependencies:
  plugin-json:
    git: https://github.com/aro-plugins/json
    ref: v1.0.0

  plugin-http:
    git: https://github.com/aro-plugins/http
    ref: v2.1.0
```

Declares other ARO plugins this plugin depends on.

Fields per dependency:
- `git`: Repository URL
- `ref`: Git reference (tag recommended)
- `commit`: Specific commit (optional, for pinning)

### dev-dependencies

```yaml
dev-dependencies:
  plugin-test-utils:
    git: https://github.com/aro-plugins/test-utils
    ref: v1.0.0
```

Dependencies only needed for development/testing.

## Platform-Specific Configuration

### platforms

```yaml
platforms:
  macos:
    min-version: "13.0"
    architectures: [arm64, x86_64]

  linux:
    distributions:
      - ubuntu-22.04
      - debian-12

  windows:
    min-version: "10"
```

Declares supported platforms and requirements.

### platform-specific provides

```yaml
provides:
  - type: c-plugin
    path: src/
    platforms:
      macos:
        build:
          libs:
            - "-framework CoreFoundation"
      linux:
        build:
          libs:
            - "-lpthread"
            - "-ldl"
```

## Complete Example

```yaml
name: plugin-formatter
version: 2.1.0
description: Date, time, number, and currency formatting utilities
author: ARO Community <community@arolang.dev>
license: MIT
homepage: https://github.com/aro-plugins/formatter
repository: https://github.com/aro-plugins/formatter

keywords:
  - formatting
  - dates
  - currency
  - localization
  - i18n

aro-version: ">=0.9.0 <2.0.0"

source:
  git: https://github.com/aro-plugins/formatter
  ref: v2.1.0

provides:
  - type: swift-plugin
    path: Sources/FormatterPlugin/
    actions:
      - name: formatDate
        description: Format a date according to a pattern and locale
      - name: formatTime
        description: Format a time with timezone support
      - name: formatNumber
        description: Format a number with grouping and decimals
      - name: formatCurrency
        description: Format a number as currency
      - name: formatDuration
        description: Format a duration in human-readable form

  - type: aro-files
    path: features/
    description: High-level formatting utilities

dependencies:
  plugin-locale:
    git: https://github.com/aro-plugins/locale
    ref: v1.2.0

dev-dependencies:
  plugin-test-utils:
    git: https://github.com/aro-plugins/test-utils
    ref: v1.0.0

platforms:
  macos:
    min-version: "13.0"
  linux:
    distributions: [ubuntu-22.04, debian-12, fedora-38]
```

## Validation

ARO validates your manifest when loading the plugin. Common validation errors:

| Error | Cause |
|-------|-------|
| `Missing required field: name` | `name` field not provided |
| `Invalid version format` | Version doesn't match semver |
| `Invalid aro-version constraint` | Malformed version constraint |
| `Unknown provide type` | `type` field has invalid value |
| `Path not found` | Declared `path` doesn't exist |
| `Circular dependency detected` | Dependencies form a cycle |

Use `aro check` to validate your manifest:

```bash
aro check ./my-plugin
```
