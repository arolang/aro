# Chapter 4: The plugin.yaml Manifest

*"A good specification is a love letter to your future self."*

---

Every plugin has a story to tell—what it's called, what it provides, how to build it, what it depends on. The `plugin.yaml` manifest is where that story is written. This chapter is your complete reference to the manifest format.

## 4.1 Why plugin.yaml?

The manifest is mandatory. Without it, ARO won't recognize a directory as a plugin.

This isn't bureaucracy for its own sake. The manifest serves crucial purposes:

**Identification**: The `name` and `version` fields uniquely identify your plugin. When conflicts arise or bugs are reported, this identification is essential.

**Discovery**: The `provides` field tells ARO exactly what types of components your plugin contains. No guessing, no recursive scanning—ARO knows immediately what to expect.

**Reproducibility**: The `source` field documents where the plugin came from. When your colleague clones your project, they can see exactly which commit of which repository each plugin represents.

**Dependencies**: The `dependencies` field enables ARO to verify that required plugins are present before attempting to load your plugin.

## 4.2 Minimal Manifest

A valid manifest needs only three things:

```yaml
name: my-plugin
version: 1.0.0
provides:
  - type: c-plugin
    path: src/
```

That's it. Name, version, and at least one provider. Everything else is optional.

But optional doesn't mean unimportant. A well-crafted manifest makes your plugin easier to use, debug, and maintain.

## 4.3 Complete Manifest Structure

Here's a fully-specified manifest showing all available fields:

```yaml
# Identity
name: plugin-example
version: 1.0.0
description: "An example plugin demonstrating the complete manifest format"
author: "Your Name <your.email@example.com>"
license: MIT
aro-version: ">=0.1.0"

# Origin (automatically populated by `aro add`)
source:
  git: "https://github.com/you/plugin-example"
  ref: "main"
  commit: "abc123def456789..."

# What this plugin provides
provides:
  - type: c-plugin
    path: src/
    build:
      compiler: clang
      flags: ["-O2", "-fPIC", "-shared"]
      output: libexample.dylib

# Dependencies on other plugins
dependencies:
  plugin-utils:
    git: "https://github.com/arolang/plugin-utils"
    ref: "v1.0.0"

# Build configuration
build:
  swift:
    minimum-version: "6.2"
    targets:
      - name: ExamplePlugin
        path: Sources/
```

Let's examine each section.

## 4.4 Identity Fields

### name

```yaml
name: plugin-csv-processor
```

The plugin's unique identifier. Conventions:

- Use lowercase letters, numbers, and hyphens only
- Start with `plugin-` for public plugins (recommended, not required)
- Choose descriptive names that indicate functionality
- Keep it reasonably short—this appears in error messages and commands

The name is used in:
- `aro plugins list` output
- Service names in ARO code (`<plugin-csv-processor: parse>`)
- The `aro remove` command

### version

```yaml
version: 1.2.3
```

A semantic version number following the `major.minor.patch` convention:

- **Major**: Breaking changes to the plugin's interface
- **Minor**: New features that maintain backward compatibility
- **Patch**: Bug fixes and minor improvements

Start at `1.0.0` when your plugin is ready for others to use. Use `0.x.y` during initial development when the interface is still in flux.

### description

```yaml
description: "High-performance CSV parsing with support for custom delimiters"
```

A brief description of what the plugin does. This appears in `aro plugins list --verbose`. Keep it under 100 characters if possible.

### author

```yaml
author: "Jane Developer <jane@example.com>"
```

The plugin author or maintainer. Can be a name, email, or both. For team projects, use a group name:

```yaml
author: "ARO Core Team"
```

### license

```yaml
license: MIT
```

The software license. Common values:
- `MIT` - permissive, widely compatible
- `Apache-2.0` - permissive with patent grants
- `GPL-3.0` - copyleft
- `Proprietary` - for internal plugins

### aro-version

```yaml
aro-version: ">=0.1.0"
```

The minimum ARO version required. Uses semantic version constraints:

| Constraint | Meaning |
|------------|---------|
| `>=0.1.0` | Version 0.1.0 or higher |
| `>=0.2.0 <1.0.0` | At least 0.2.0 but less than 1.0.0 |
| `~>0.3.0` | Compatible with 0.3.x (0.3.0 to 0.3.99) |
| `^0.5.0` | Compatible with 0.x.x starting at 0.5.0 |

During ARO's pre-1.0 development, minor versions may include breaking changes. Be conservative with version constraints.

## 4.5 Source Fields

The `source` section documents where the plugin came from:

```yaml
source:
  git: "https://github.com/arolang/plugin-rust-csv"
  ref: "main"
  commit: "e1ea0866dd24a9fcb7c7ecfe05d1e7faad055d3c"
```

### git

The repository URL. Supports both HTTPS and SSH:

```yaml
# HTTPS (public repositories)
git: "https://github.com/arolang/plugin-example"

# SSH (private repositories or when you have SSH keys)
git: "git@github.com:arolang/plugin-example.git"
```

### ref

The Git reference that was checked out:

```yaml
ref: "main"           # Branch
ref: "v1.2.0"         # Tag
ref: "feature/new"    # Feature branch
```

### commit

The specific commit SHA. This ensures reproducibility—anyone can verify exactly which version of the code is installed:

```yaml
commit: "57feae01b1af5705f823a34ef3eb3757e40664fe"
```

**Note**: The `source` section is automatically populated when you use `aro add`. For manually-created local plugins, you can omit this section entirely.

## 4.6 Provider Types

The `provides` section declares what components your plugin contains. Each entry specifies a provider type and its location.

### c-plugin

C plugins compile to dynamic libraries:

```yaml
provides:
  - type: c-plugin
    path: src/
    build:
      compiler: clang
      flags: ["-O2", "-fPIC", "-shared"]
      output: libexample.dylib
```

**Fields:**

- `path`: Directory containing C source files
- `build.compiler`: The C compiler (`clang` or `gcc`)
- `build.flags`: Compiler flags as an array
- `build.output`: Name of the generated library

Platform considerations:
- macOS: `.dylib` extension
- Linux: `.so` extension
- Windows: `.dll` extension

### rust-plugin

Rust plugins use Cargo for building:

```yaml
provides:
  - type: rust-plugin
    path: src/
    build:
      cargo-target: release
      output: target/release/libcsv_plugin.dylib
```

**Fields:**

- `path`: Directory containing `Cargo.toml`
- `build.cargo-target`: Build profile (`release` or `debug`)
- `build.output`: Path to the generated library

The `Cargo.toml` must specify `crate-type = ["cdylib"]` for ARO compatibility.

### swift-plugin

Swift plugins can be either single-file or package-based:

```yaml
provides:
  - type: swift-plugin
    path: Sources/
```

For Swift packages with dependencies:

```yaml
provides:
  - type: swift-plugin
    path: Sources/

build:
  swift:
    minimum-version: "6.2"
    targets:
      - name: HelloPlugin
        path: Sources/
```

### python-plugin

Python plugins run in a subprocess:

```yaml
provides:
  - type: python-plugin
    path: src/
    python:
      min-version: "3.9"
      requirements: requirements.txt
```

**Fields:**

- `path`: Directory containing Python files
- `python.min-version`: Minimum Python version required
- `python.requirements`: Path to pip requirements file

### aro-files

ARO feature set files that extend your application:

```yaml
provides:
  - type: aro-files
    path: features/
```

These `.aro` files are parsed and their feature sets registered with the runtime. Feature sets from plugins can serve two purposes:

**1. Event Handlers**: Feature sets with business activity matching `<EventName> Handler` automatically become event handlers. When your application emits a matching event, the handler executes:

```aro
(* In plugin's features/handlers.aro *)
(Log User Events: UserCreated Handler) {
    <Log> "[AUDIT] User created" to the <console>.
    <Return> an <OK: status> for the <audit>.
}
```

When any application using this plugin emits `<Emit> a <UserCreated: event>`, the handler runs automatically.

**2. Reusable Feature Sets**: Other feature sets become available for use via the `<Invoke>` action or as building blocks for your application logic.

A plugin containing *only* `aro-files` is called a **pure ARO plugin**—the simplest plugin type, requiring no native code or compilation. See Chapter 14 for a complete example.

### cpp-plugin

C++ plugins require `extern "C"` wrappers:

```yaml
provides:
  - type: cpp-plugin
    path: src/
    build:
      compiler: clang++
      flags: ["-O2", "-fPIC", "-shared", "-std=c++17"]
      output: libexample.dylib
```

### Multiple Providers

A single plugin can provide multiple component types:

```yaml
provides:
  # Native code for performance-critical operations
  - type: swift-plugin
    path: Sources/

  # ARO feature sets for business logic
  - type: aro-files
    path: features/
```

This "hybrid" pattern combines the performance of native code with the readability of ARO syntax.

## 4.7 Dependencies

The `dependencies` section declares other plugins your plugin requires:

```yaml
dependencies:
  plugin-core-utils:
    git: "https://github.com/arolang/plugin-core-utils"
    ref: "v2.0.0"

  plugin-logging:
    git: "https://github.com/arolang/plugin-logging"
    ref: "v1.5.0"
```

Each dependency is keyed by its plugin name and specifies:

- `git`: Repository URL
- `ref`: Version, tag, or branch

When ARO loads your plugin, it first verifies that all dependencies are present in the `Plugins/` directory. Missing dependencies trigger clear error messages:

```
Error: Plugin 'plugin-csv-advanced' requires 'plugin-core-utils',
       but it is not installed.

Install with: aro add https://github.com/arolang/plugin-core-utils --ref v2.0.0
```

### Dependency Resolution

ARO resolves dependencies using topological sorting. If Plugin A depends on Plugin B, Plugin B is loaded first. This ensures that when your plugin initializes, all its dependencies are already available.

Circular dependencies are detected and reported:

```
Error: Circular dependency detected:
  plugin-a → plugin-b → plugin-c → plugin-a
```

## 4.8 Build Configuration

The top-level `build` section provides additional build configuration:

### Swift Build

```yaml
build:
  swift:
    minimum-version: "6.2"
    targets:
      - name: MyPlugin
        path: Sources/
```

- `minimum-version`: Required Swift compiler version
- `targets`: List of Swift targets to build

### Rust Build

Rust builds are configured through `Cargo.toml`, but you can specify additional options:

```yaml
build:
  rust:
    edition: "2021"
    features: ["json", "async"]
```

### C/C++ Build

C and C++ build options are typically specified in the provider section:

```yaml
provides:
  - type: c-plugin
    path: src/
    build:
      compiler: clang
      flags:
        - "-O2"
        - "-fPIC"
        - "-shared"
        - "-I/usr/local/include"
      link:
        - "-L/usr/local/lib"
        - "-lsqlite3"
      output: libplugin.dylib
```

## 4.9 Real-World Examples

### Hash Plugin (C)

A minimal C plugin for cryptographic hashing:

```yaml
name: plugin-c-hash
version: 1.0.0
description: A C plugin for computing various hash functions
author: ARO Team
license: MIT
aro-version: '>=0.1.0'
source:
  git: git@github.com:arolang/plugin-c-hash.git
  ref: main
  commit: 57feae01b1af5705f823a34ef3eb3757e40664fe
provides:
  - type: c-plugin
    path: src/
    build:
      compiler: clang
      flags:
        - -O2
        - -fPIC
        - -shared
      output: libhash_plugin.dylib
```

### CSV Processor (Rust)

A Rust plugin for CSV operations:

```yaml
name: plugin-rust-csv
version: 1.0.0
description: A Rust plugin for CSV parsing and formatting
author: ARO Team
license: MIT
aro-version: '>=0.1.0'
source:
  git: https://github.com/arolang/plugin-rust-csv
  ref: main
  commit: e1ea0866dd24a9fcb7c7ecfe05d1e7faad055d3c
provides:
  - type: rust-plugin
    path: src/
    build:
      cargo-target: release
      output: target/release/libcsv_plugin.dylib
```

### Greeting Plugin (Swift Hybrid)

A Swift plugin that also provides ARO feature sets:

```yaml
name: plugin-swift-hello
version: 1.0.0
description: A simple Swift plugin that provides greeting functionality
author: ARO Team
license: MIT
aro-version: '>=0.1.0'
source:
  git: https://github.com/arolang/plugin-swift-hello
  ref: main
  commit: 29d3cd4861c3788ecd33377e8301a08fca003dee
provides:
  - type: swift-plugin
    path: Sources/
  - type: aro-files
    path: features/
build:
  swift:
    minimum-version: '6.2'
    targets:
      - name: HelloPlugin
        path: Sources/
```

### Data Analyzer (Python)

A Python plugin for data analysis and ML:

```yaml
name: plugin-python-analyzer
version: 1.0.0
description: Data analysis and ML inference via Python
author: ARO Community
license: MIT
aro-version: '>=0.2.0'
provides:
  - type: python-plugin
    path: src/
    python:
      min-version: "3.9"
      requirements: requirements.txt
```

## 4.10 Validation

ARO validates manifests when plugins are loaded. Common validation errors:

**Missing required field:**
```
Error: plugin.yaml validation failed: 'name' is required
```

**Invalid version format:**
```
Error: plugin.yaml validation failed: 'version' must be semver (got: "1.0")
```

**Unknown provider type:**
```
Error: plugin.yaml validation failed: unknown provider type 'java-plugin'
```

**Path doesn't exist:**
```
Error: plugin.yaml validation failed: path 'src/' does not exist
```

Use `aro plugins list --verbose` to see detailed information about installed plugins and any validation warnings.

## 4.11 Best Practices

### Version Thoughtfully

Don't increment versions carelessly. Your users depend on semantic versioning to understand the impact of updates:

- Bump **patch** for bug fixes
- Bump **minor** for new features
- Bump **major** for breaking changes

### Document Dependencies

If your plugin depends on system libraries or external tools, document them in your README:

```markdown
## Requirements

- FFmpeg 5.0 or later
- clang compiler

### macOS
```bash
brew install ffmpeg
```

### Ubuntu
```bash
apt install ffmpeg libavcodec-dev
```
```

### Keep Descriptions Accurate

The description field appears in plugin listings. Make it useful:

```yaml
# Good
description: "High-performance CSV parsing with custom delimiters and encoding support"

# Less helpful
description: "A plugin"
```

### Use Consistent Naming

Follow the ecosystem conventions:

```yaml
# Good
name: plugin-rust-csv
name: plugin-c-hash
name: plugin-swift-hello

# Inconsistent
name: csvparser
name: MyHashPlugin
name: swift_hello
```

## 4.12 Summary

The `plugin.yaml` manifest is your plugin's identity card. Required fields:

- `name`: Unique identifier
- `version`: Semantic version
- `provides`: At least one provider with type and path

Recommended fields:

- `description`: What your plugin does
- `author`: Who maintains it
- `license`: Usage terms
- `aro-version`: Compatibility requirements

The manifest enables ARO's lockfile-free architecture—everything ARO needs to know about a plugin is contained in the plugin itself.

With this foundation complete, you're ready to start writing plugins. The next chapter begins with Swift.

