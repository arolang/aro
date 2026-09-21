# CustomPlugin

Demonstrates extending ARO with custom service plugins written in Swift.

## What It Does

Loads a Swift plugin from `Plugins/GreetingService/` and invokes the two actions
it exports, `Greeting.Hello` and `Greeting.Goodbye`, as ordinary statements.

## Features Tested

- **Plugin loading** — a `plugin.yaml` manifest inside `Plugins/<name>/`
- **Namespaced actions** — `Handle.Verb`, where `Greeting` is the plugin's
  root-level `handle:` (ARO-0087)
- **C-compatible interface** — JSON in, JSON out, across the
  `aro_plugin_info`/`execute`/`free` ABI the SDK generates
- **Application lifecycle** — `Application-End: Success` for cleanup

This README described `plugins/GreetingService.swift`, the `Call` action and
`aro_plugin_init` — the pre-plugin model ARO-0016 documented and which never
shipped (GitLab #818, #833). The plugin is a Swift package under `Plugins/` and
is built by `aro run` on first use.

## Related Proposals

- [ARO-0016: Interoperability](../../Proposals/ARO-0016-interoperability.md)
- [ARO-0004: Actions](../../Proposals/ARO-0004-actions.md)

## Usage

```bash
# Run with plugin loading
aro run ./Examples/CustomPlugin

# Build (plugin compiled on first run)
aro build ./Examples/CustomPlugin
./Examples/CustomPlugin/CustomPlugin
```

### ⚠️ macOS Code Signing Note

On macOS, plugin loading may fail with this error:
```
dlopen(): code signature not valid for use in process:
mapping process and mapped file have different Team IDs
```

This is a **macOS security feature**, not an ARO bug. The code is correct.

**Workarounds for Development:**

1. **Disable library validation** (requires sudo):
   ```bash
   sudo codesign --force --sign - --deep /opt/homebrew/bin/aro
   # Clear cached plugin
   rm -f ~/.aro-cache/GreetingService.dylib
   # Run
   aro run ./Examples/CustomPlugin
   ```

2. **Use local build** (recommended):
   ```bash
   swift build -c debug
   rm -f .aro-cache/GreetingService.dylib
   aro run ./Examples/CustomPlugin
   ```

**Production Solution:**
Code-sign both ARO and plugins with the same Apple Developer Team ID.

## Project Structure

```
CustomPlugin/
├── main.aro              # ARO code calling the plugin
├── aro.yaml              # Plugin configuration
└── Plugins/
    └── GreetingService/
        ├── plugin.yaml            # Manifest: name, handle, provides
        ├── Package.swift          # Swift package
        └── Sources/
            └── GreetingService.swift
```

## Example Output

```
Testing custom greeting plugin...
Hello, ARO Developer!
Goodbye, ARO Developer! See you next time.
Custom plugin demo completed.
```

---

*Extensibility without complexity. Drop in a Swift file, configure it once, and your custom services become first-class ARO citizens.*
