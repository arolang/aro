# CustomPlugin

Demonstrates extending ARO with custom service plugins written in Swift.

## What It Does

Loads a custom greeting service from a Swift plugin and calls its methods (`hello`, `goodbye`) from ARO code. Shows the plugin initialization and C-compatible interface used for ARO integration.

## Features Tested

- **Plugin loading** - `aro.yaml` configuration for plugin discovery
- **Service registration** - Plugins expose services via `aro_plugin_init`
- **Method invocation** - `<Call>` action with service and method syntax
- **C-compatible interface** - JSON-based input/output for cross-language calls
- **Application lifecycle** - `Application-End: Success` for cleanup

## Related Proposals

- [ARO-0025: Plugin Architecture](../../Proposals/ARO-0025-plugin-architecture.md)
- [ARO-0020: Action Framework](../../Proposals/ARO-0020-action-framework.md)

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
   .build/debug/aro run ./Examples/CustomPlugin
   ```

**Production Solution:**
Code-sign both ARO and plugins with the same Apple Developer Team ID.

## Project Structure

```
CustomPlugin/
├── main.aro              # ARO code calling the plugin
├── aro.yaml              # Plugin configuration
└── plugins/
    └── GreetingService.swift  # Plugin source
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
