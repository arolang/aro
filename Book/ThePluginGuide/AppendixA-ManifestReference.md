# Appendix A: plugin.yaml Reference

This appendix provides a complete reference for the `plugin.yaml` manifest file format.

## Overview

The `plugin.yaml` file is the manifest that describes your plugin to ARO. It must be placed at the root of your plugin directory.

```yaml
name: my-plugin
version: 1.0.0
handle: MyPlugin
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
      - name: FormatDate
        verbs: [formatdate]
        role: own
        prepositions: [from, with]

dependencies:
  some-other-plugin:
    git: https://github.com/other/plugin
    ref: v2.0.0
```

## What the loader reads

The manifest is decoded into a fixed set of fields, and **anything else is
silently ignored**. That is worth stating plainly, because a plausible-looking
key that the loader does not know about costs you the behaviour without an
error message.

The recognised top-level keys are exactly: `name`, `version`, `handle`,
`description`, `author`, `license`, `aro-version`, `source`, `provides`,
`dependencies`, `platforms`.

Inside a `provides` entry: `type`, `path`, `handler`, `build`, `python`,
`actions`.

Inside `build`: `cargo-target`, `compiler`, `flags`, `output`.

Popular fields from other package managers — `homepage`, `repository`,
`keywords`, `authors`, `dev-dependencies` — are **not** read. Neither is a
top-level `build:` block, nor `system-objects`, `include`, `libs`, `standard`,
`features` or `profile` inside `build`. Include them for human readers if you
like; do not expect them to do anything.

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

### handle

```yaml
handle: MyPlugin
```

The plugin's namespace: the name callers actually type. A plugin with
`handle: Markdown` exposes its actions as `Markdown.ToHTML` and its qualifiers
as `<value: Markdown.escape>`.

Conventions the loader checks and warns about:

- **PascalCase.** It must start with an uppercase letter, and contain no
  hyphens or underscores. `markdown` or `my-plugin` load, but log a warning
  suggesting the PascalCase form.
- **Unique across the application.** If a second plugin claims a handle
  already taken, the loader logs an error and loads that plugin *without a
  namespace* — its qualifiers then become unreachable, since qualifiers have
  no bare form.

Omitting `handle` is legal only for plugins with no native or Python actions —
a pure `aro-files` plugin, for instance.

**Legacy form.** Before the root-level `handle`, the namespace was a `handler`
key inside a `provides` entry, lowercase:

```yaml
provides:
  - type: c-plugin
    path: src/
    handler: collections     # deprecated
```

That still works and is still honoured, but it logs a deprecation warning
naming the PascalCase replacement. Root-level `handle` wins when both are
present. New plugins should use `handle` only.

### description

```yaml
description: Provides date, time, and currency formatting utilities
```

A brief description (recommended: one sentence, max 200 characters).

### author

```yaml
author: Jane Developer <jane@example.com>
```

A single string. There is no plural `authors` list; for a team, name the team:

```yaml
author: ARO Core Team
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

### homepage, repository, keywords

Not read by the loader. Put your homepage and repository in the README, and
the canonical repository URL in `source.git`, where `aro add` writes it.

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
- `ref`: Git reference — tag, branch, or commit (recommended: use tags)
- `commit`: Specific commit SHA (for pinning)

`aro add` writes all three for you; hand-written local plugins can omit
`source` entirely.

## Provides Section

The `provides` array declares what your plugin offers.

### Swift Plugin

```yaml
provides:
  - type: swift-plugin
    path: Sources/MyPlugin/
    actions:
      - name: FormatDate
        verbs: [formatdate]
        description: Format a date according to a pattern
      - name: FormatCurrency
        verbs: [formatcurrency]
        description: Format a number as currency
```

Fields:
- `type`: `swift-plugin`
- `path`: Path to Swift sources (relative to plugin.yaml)
- `actions`: List of action definitions (see Action Specification below)

### Action Specification

Declaring `actions` in the manifest is optional, and it does something specific:
it lets the loader register action **stubs** at startup and defer the actual
`dlopen` (or `cargo build`, or first `python3`) to the first time an ARO
statement invokes one of them. Omit `actions` and the plugin loads eagerly,
taking its action list from `aro_plugin_info` instead. An application shipping
several plugins that uses one per request starts noticeably faster with them
declared.

```yaml
actions:
  - name: Hash
    verbs: [hash, digest, checksum]
    role: own
    prepositions: [from, with]
    description: Compute cryptographic hash
    since: "1.2.0"
```

**Action Fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Action identifier |
| `verbs` | **Yes** | Verbs that trigger this action |
| `description` | No | Human-readable description (shown in editor hover and `aro_actions` MCP output) |
| `role` | No | Semantic role: `request`, `own`, `response`, `export` |
| `prepositions` | No | Valid prepositions for this action |
| `since` | No | Version when the action was introduced (informational, surfaced in tooling) |

**`verbs` is required, and getting it wrong is fatal to the whole plugin.** An
entry without it fails to decode, and because the manifest decodes as a unit,
the plugin does not load at all:

```
warning: Failed to load my-plugin: DecodingError.keyNotFound: Key 'verbs' not
found in keyed decoding container. Path: provides[0].actions[0].
```

The same applies to the bare-string shorthand — `actions: [formatDate,
formatCurrency]` is not accepted here. (It *is* accepted in the JSON returned
by `aro_plugin_info`, which is a different parser; do not carry the habit
across.) There is no `arguments` field: argument schemas are not read from the
manifest.

The `description`, `role`, `prepositions`, and `since` fields are also consumed by the LSP and the MCP `aro_actions` / `aro_qualifiers` tools — the richer the manifest, the better the editor experience for downstream users.

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
Hash the <result: sha256> from the <data>.
Digest the <checksum> from the <file>.

(* Without verbs - only via Call: *)
Call the <result> from the <plugin: processData> with { ... }.
```

### Rust Plugin

```yaml
provides:
  - type: rust-plugin
    path: src/
    build:
      cargo-target: release
      output: target/release/libmy_plugin.dylib
    actions:
      - name: Validate
        verbs: [validate]
      - name: Transform
        verbs: [transform]
```

Fields:
- `type`: `rust-plugin`
- `path`: Path to Cargo project
- `build`:
  - `cargo-target`: Build profile — `release` or `debug`. (Not the crate type;
    set `crate-type = ["cdylib"]` in `Cargo.toml`.)
  - `output`: Path to the produced library, relative to the plugin directory

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
        - "-Iinclude"
        - "-lz"
      output: libmyplugin.dylib
```

Fields:
- `type`: `c-plugin`
- `path`: Path to C sources
- `build`:
  - `compiler`: Compiler to use (`clang`, `gcc`)
  - `flags`: Compiler flags — the only list there is. There are no separate
    `include` or `libs` keys; put `-I` and `-l` flags here.
  - `output`: Output library file name, **with** the platform extension

### C++ Plugin

```yaml
provides:
  - type: cpp-plugin
    path: src/
    build:
      compiler: clang++
      flags:
        - "-O2"
        - "-Wall"
        - "-std=c++17"
        - "-lstdc++"
```

Fields:
- `type`: `cpp-plugin`
- Same as C plugin. There is no `standard` key — pass `-std=c++17` in `flags`.

### Python Plugin

```yaml
provides:
  - type: python-plugin
    path: src/
    python:
      min-version: "3.9"
      requirements: requirements.txt
    actions:
      - name: Generate
        verbs: [generate]
      - name: Summarize
        verbs: [summarize]
```

Fields:
- `type`: `python-plugin`
- `path`: Path to Python sources
- `python`:
  - `min-version`: Minimum Python version
  - `requirements`: Path to requirements.txt

  There is no `venv` key — the loader runs whichever `python3` it finds.

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
    Log "[AUDIT] User created" to the <console>.
    Return an <OK: status> for the <audit>.
}
```

A plugin with only `aro-files` providers (no native code) is called a **pure ARO plugin**.

### System Objects

System objects are **not** declared in `plugin.yaml`. The loader has no
`system-objects` key inside a `provides` entry and ignores one if present.
Declare them at runtime instead, in the `system_objects` array your
`aro_plugin_info` returns:

```json
"system_objects": [
  { "identifier": "redis",
    "capabilities": ["readable", "writable", "enumerable"],
    "description": "Redis key-value store" }
]
```

The key is `identifier`, not `name`. See Chapter 13 and Appendix B.

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
- `git`: Repository URL (required)
- `ref`: Git reference (tag recommended)

A dependency has no `commit` field — only `source` (which records where *this*
plugin came from) carries one.

### dev-dependencies

Not supported. There is no separate development dependency set; the loader
reads only `dependencies`. Document test-only plugins in your README.

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

`platforms` is a **top-level** key only. A `platforms` block nested inside a
`provides` entry is ignored, so per-platform link flags cannot be expressed in
the manifest today. Select them in your Makefile or `build.rs` from `uname`,
the way the scaffolded C Makefile does.

## Complete Example

```yaml
name: plugin-formatter
version: 2.1.0
description: Date, time, number, and currency formatting utilities
author: ARO Community <community@arolang.dev>
license: MIT
handle: Formatter

aro-version: ">=0.9.0 <2.0.0"

source:
  git: https://github.com/aro-plugins/formatter
  ref: v2.1.0

provides:
  - type: swift-plugin
    path: Sources/FormatterPlugin/
    actions:
      - name: FormatDate
        verbs: [formatdate]
        description: Format a date according to a pattern and locale
      - name: FormatTime
        verbs: [formattime]
        description: Format a time with timezone support
      - name: FormatNumber
        verbs: [formatnumber]
        description: Format a number with grouping and decimals
      - name: FormatCurrency
        verbs: [formatcurrency]
        description: Format a number as currency
      - name: FormatDuration
        verbs: [formatduration]
        description: Format a duration in human-readable form

  - type: aro-files
    path: features/

dependencies:
  plugin-locale:
    git: https://github.com/aro-plugins/locale
    ref: v1.2.0

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
