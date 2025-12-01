# ARO-0026: Native Compilation

**Status:** Implemented
**Version:** 1.0.0
**Authors:** Claude, ARO Team

## Summary

This proposal introduces native binary compilation support for ARO applications via the `aro build` command. ARO programs can be compiled to C code and then to native machine code, enabling deployment without the Swift runtime while maintaining full access to runtime services through a Swift-based runtime library.

## Motivation

While the interpreted `aro run` command is excellent for development and quick iteration, production deployments often benefit from native compilation:

1. **Faster startup** - No interpreter initialization overhead
2. **Lower memory footprint** - No interpreter runtime in memory
3. **Distribution simplicity** - Single binary deployment
4. **Cross-platform deployment** - Compile for different targets
5. **Integration** - Link with existing C/C++ codebases

## Design Overview

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    ARO Source Files                          │
│                  (.aro / .fdd files)                        │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                    AROParser                                 │
│           (Lexer → Parser → Semantic Analyzer)              │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                  AROCompiler                                 │
│               CCodeGenerator                                 │
│    (Transforms AST to C source code)                        │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                 Generated C Code                             │
│           (Feature sets as functions)                        │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                  CCompiler (clang/gcc)                       │
│           (Compiles C to object file)                        │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                    Linker                                    │
│     (Links with libAROCRuntime.a Swift library)             │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                  Native Binary                               │
│            (Standalone executable)                           │
└─────────────────────────────────────────────────────────────┘
```

### Components

#### 1. CCodeGenerator

Transforms the analyzed AST into C source code:

- Each feature set becomes a C function
- ARO statements become calls to runtime bridge functions
- Literal values are bound to context variables
- `Application-Start` feature set generates `main()` entry point

#### 2. AROCRuntime (Swift Static Library)

A Swift static library exposing C-callable functions via `@_cdecl`:

```swift
@_cdecl("aro_runtime_init")
public func aro_runtime_init() -> UnsafeMutableRawPointer? { ... }

@_cdecl("aro_action_extract")
public func aro_action_extract(
    _ ctx: UnsafeRawPointer?,
    _ result: UnsafeRawPointer?,
    _ object: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? { ... }
```

#### 3. CCompiler

Wrapper around system C compiler (clang/gcc):

- Detects available compiler
- Handles platform-specific flags
- Manages optimization levels

## Usage

### Basic Build

```bash
# Compile to C and object file
aro build ./MyApp

# Emit only C code (for inspection or custom compilation)
aro build ./MyApp --emit-c

# Enable optimizations
aro build ./MyApp --optimize

# Verbose output
aro build ./MyApp --verbose

# Keep intermediate files
aro build ./MyApp --keep-intermediate
```

### Output Files

```
MyApp/
├── main.aro
└── .build/
    ├── MyApp.c    # Generated C code
    └── MyApp.o    # Compiled object file
```

### Full Linking

```bash
# Build the Swift runtime library first
swift build -c release

# Link the object file with the runtime
clang MyApp/.build/MyApp.o \
    -L.build/release \
    -lAROCRuntime \
    -L$(xcrun --show-sdk-path)/usr/lib/swift \
    -lswiftCore \
    -o MyApp
```

## Generated C Code Structure

For an ARO program:

```aro
(Application-Start: Entry Point) {
    <Create> the <greeting: String> with "Hello, World!".
    <Log> the <greeting> for the <console>.
    <Return> an <OK: status> for the <application>.
}
```

The generated C code:

```c
#include <stdio.h>
#include <stdlib.h>

// ARO Runtime declarations
typedef void* ARORuntime;
typedef void* AROContext;
typedef void* AROValue;

extern ARORuntime aro_runtime_init(void);
extern void aro_runtime_shutdown(ARORuntime runtime);
extern AROContext aro_context_create_named(ARORuntime runtime, const char* name);
extern void aro_context_destroy(AROContext ctx);
extern void aro_variable_bind_string(AROContext ctx, const char* name, const char* value);
extern AROValue aro_action_create(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
extern AROValue aro_action_log(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
extern AROValue aro_action_return(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);

// Feature Set: Application-Start
AROValue aro_fs_application_start(AROContext ctx) {
    AROValue __result = NULL;

    // <Create> the <greeting> ...
    {
        aro_variable_bind_string(ctx, "_literal_", "Hello, World!");
        const char* result_specs[] = { "String" };
        AROResultDescriptor result_desc = { "greeting", result_specs, 1 };
        AROObjectDescriptor object_desc = { "_literal_", 3, NULL, 0 };
        __result = aro_action_create(ctx, &result_desc, &object_desc);
    }

    // <Log> the <greeting> ...
    {
        AROResultDescriptor result_desc = { "greeting", NULL, 0 };
        AROObjectDescriptor object_desc = { "console", 2, NULL, 0 };
        __result = aro_action_log(ctx, &result_desc, &object_desc);
    }

    // <Return> the <OK> ...
    {
        const char* result_specs[] = { "status" };
        AROResultDescriptor result_desc = { "OK", result_specs, 1 };
        AROObjectDescriptor object_desc = { "application", 2, NULL, 0 };
        __result = aro_action_return(ctx, &result_desc, &object_desc);
    }

    return __result;
}

// Main entry point
int main(int argc, char* argv[]) {
    ARORuntime runtime = aro_runtime_init();
    if (!runtime) {
        fprintf(stderr, "Failed to initialize ARO runtime\n");
        return 1;
    }

    AROContext ctx = aro_context_create_named(runtime, "Application-Start");
    AROValue result = aro_fs_application_start(ctx);

    if (result) aro_value_free(result);
    aro_context_destroy(ctx);
    aro_runtime_shutdown(runtime);

    return 0;
}
```

## Runtime Bridge Functions

### Lifecycle

| Function | Description |
|----------|-------------|
| `aro_runtime_init` | Initialize the ARO runtime |
| `aro_runtime_shutdown` | Shutdown and cleanup |
| `aro_context_create` | Create execution context |
| `aro_context_create_named` | Create named context |
| `aro_context_destroy` | Destroy context |

### Variables

| Function | Description |
|----------|-------------|
| `aro_variable_bind_string` | Bind string value |
| `aro_variable_bind_int` | Bind integer value |
| `aro_variable_bind_double` | Bind float value |
| `aro_variable_bind_bool` | Bind boolean value |
| `aro_variable_resolve` | Resolve variable value |
| `aro_value_free` | Free value memory |

### Actions

All 24 built-in actions are exposed:

| Function | Semantic Role |
|----------|---------------|
| `aro_action_extract` | REQUEST |
| `aro_action_fetch` | REQUEST |
| `aro_action_retrieve` | REQUEST |
| `aro_action_parse` | REQUEST |
| `aro_action_read` | REQUEST |
| `aro_action_compute` | OWN |
| `aro_action_validate` | OWN |
| `aro_action_compare` | OWN |
| `aro_action_transform` | OWN |
| `aro_action_create` | OWN |
| `aro_action_update` | OWN |
| `aro_action_return` | RESPONSE |
| `aro_action_throw` | RESPONSE |
| `aro_action_emit` | EXPORT |
| `aro_action_send` | EXPORT |
| `aro_action_log` | EXPORT |
| `aro_action_store` | EXPORT |
| `aro_action_write` | EXPORT |
| `aro_action_publish` | EXPORT |
| `aro_action_start` | SERVER |
| `aro_action_listen` | SERVER |
| `aro_action_route` | SERVER |
| `aro_action_watch` | SERVER |
| `aro_action_stop` | SERVER |

### HTTP Server

| Function | Description |
|----------|-------------|
| `aro_http_server_create` | Create HTTP server instance |
| `aro_http_server_start` | Start listening on host:port |
| `aro_http_server_stop` | Stop the server |
| `aro_http_server_destroy` | Destroy server instance |

### File System

| Function | Description |
|----------|-------------|
| `aro_file_read` | Read file contents |
| `aro_file_write` | Write file contents |
| `aro_file_exists` | Check if file exists |
| `aro_file_delete` | Delete file |

## Platform Support

### Supported Platforms

- **macOS** (arm64, x86_64)
- **Linux** (x86_64, arm64)
- **Windows** (planned)

### Requirements

- C compiler (clang preferred, gcc supported)
- Swift toolchain (for building AROCRuntime)

## Implementation Details

### Source Files

```
Sources/
├── AROCompiler/
│   ├── CCodeGenerator.swift   # AST to C transformation
│   └── Linker.swift           # C compilation wrapper (CCompiler)
├── AROCRuntime/
│   ├── RuntimeBridge.swift    # Core runtime C interface
│   ├── ActionBridge.swift     # Action C interface
│   └── ServiceBridge.swift    # HTTP/File/Socket C interface
└── AROCLI/Commands/
    └── BuildCommand.swift     # aro build command
```

### Swift 6 Compatibility

The runtime bridge uses:
- `@unchecked Sendable` for handle classes
- `nonisolated(unsafe)` for global mutable state
- `UnsafeRawPointer` for C struct parameters

## Future Enhancements

1. **Full linking automation** - Complete binary linking without manual steps
2. **Cross-compilation** - Compile for different target architectures
3. **Static linking** - Fully static binaries without Swift runtime dependency
4. **Debug info** - DWARF debug information in compiled binaries
5. **Profile-guided optimization** - PGO support for hot paths
6. **WebAssembly target** - Compile to WASM for browser deployment

## Related Proposals

- ARO-0020: Runtime Architecture
- ARO-0021: HTTP Server
- ARO-0022: HTTP Client
- ARO-0023: File System
- ARO-0024: Sockets
