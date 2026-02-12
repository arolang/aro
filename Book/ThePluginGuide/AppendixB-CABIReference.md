# Appendix B: C ABI Function Reference

This appendix provides a complete reference for the C ABI functions that plugins must implement to integrate with ARO.

## Overview

ARO communicates with native plugins through a C-compatible Application Binary Interface (ABI). This design enables plugins written in any language that can produce C-compatible functions—Swift, Rust, C, C++, and others—to integrate seamlessly.

## Required Functions

### aro_plugin_info

Returns plugin metadata as a JSON string.

```c
const char* aro_plugin_info(void);
```

**Returns:**
- Pointer to a null-terminated JSON string (plugin retains ownership)
- The returned string must remain valid for the lifetime of the plugin

**JSON Schema:**
```json
{
  "name": "string",
  "version": "string",
  "actions": [
    {
      "name": "string",
      "symbol": "string",
      "role": "own | request | response | export",
      "verbs": ["verb1", "verb2"],
      "prepositions": ["from", "to", "with", "for", "into", "as"]
    }
  ],
  "system_objects": [
    {
      "name": "string",
      "capabilities": ["readable", "writable", "enumerable"]
    }
  ]
}
```

**Action Metadata Fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Action identifier |
| `symbol` | No | C function symbol (defaults to `aro_plugin_execute`) |
| `role` | No | Semantic role: `request`, `own`, `response`, or `export` |
| `verbs` | No | Array of verbs that trigger this action (e.g., `["hash", "digest"]`) |
| `prepositions` | No | Valid prepositions: `from`, `to`, `with`, `for`, `into`, `as`, `against`, `via` |

**Action Roles:**

| Role | Data Flow | Examples |
|------|-----------|----------|
| `request` | External → Internal | Extract, Retrieve, Fetch |
| `own` | Internal → Internal | Compute, Transform, Hash |
| `response` | Internal → External | Return, Send, Log |
| `export` | Makes data available | Publish, Store, Emit |

**Full Action Example:**
```json
{
  "name": "crypto-plugin",
  "version": "1.0.0",
  "actions": [
    {
      "name": "Hash",
      "role": "own",
      "verbs": ["hash", "digest", "checksum"],
      "prepositions": ["from", "with"],
      "description": "Compute cryptographic hash"
    },
    {
      "name": "Encrypt",
      "role": "own",
      "verbs": ["encrypt"],
      "prepositions": ["with"]
    }
  ]
}
```

This enables ARO code like:
```aro
<Hash> the <result: sha256> from the <password>.
<Encrypt> the <ciphertext> with <data> using <key>.
```

**Example Implementation (C):**
```c
static const char* plugin_info_json =
    "{"
    "  \"name\": \"my-plugin\","
    "  \"version\": \"1.0.0\","
    "  \"actions\": ["
    "    {\"name\": \"myAction\", \"symbol\": \"my_action_execute\"}"
    "  ]"
    "}";

const char* aro_plugin_info(void) {
    return plugin_info_json;
}
```

**Example Implementation (Rust):**
```rust
#[no_mangle]
pub extern "C" fn aro_plugin_info() -> *const c_char {
    static INFO: &str = r#"{
        "name": "my-plugin",
        "version": "1.0.0",
        "actions": [{"name": "myAction", "symbol": "my_action_execute"}]
    }"#;

    // Use a leaked CString for static lifetime
    CString::new(INFO).unwrap().into_raw()
}
```

**Example Implementation (Swift):**
```swift
@_cdecl("aro_plugin_info")
public func pluginInfo() -> UnsafePointer<CChar> {
    let info = """
    {"name": "my-plugin", "version": "1.0.0", "actions": [...]}
    """
    return UnsafePointer(strdup(info)!)
}
```

### aro_plugin_execute

Executes a plugin action.

```c
int32_t aro_plugin_execute(
    const char* action_name,
    const char* arguments_json,
    char** result_ptr
);
```

**Parameters:**
- `action_name`: Null-terminated string with the action name
- `arguments_json`: Null-terminated JSON string containing action arguments
- `result_ptr`: Output pointer where result JSON will be stored

**Returns:**
- `0` on success
- Non-zero error code on failure

**Result Ownership:**
- On success, `*result_ptr` must point to a heap-allocated string
- Caller (ARO runtime) will call `aro_plugin_free` to release the memory

**Example Implementation (C):**
```c
int32_t aro_plugin_execute(
    const char* action_name,
    const char* arguments_json,
    char** result_ptr
) {
    if (strcmp(action_name, "myAction") == 0) {
        // Parse arguments
        // Execute action
        // Format result

        *result_ptr = strdup("{\"result\": \"success\"}");
        return 0;
    }

    *result_ptr = strdup("{\"error\": \"Unknown action\"}");
    return 1;
}
```

**Example Implementation (Rust):**
```rust
#[no_mangle]
pub extern "C" fn aro_plugin_execute(
    action_name: *const c_char,
    arguments_json: *const c_char,
    result_ptr: *mut *mut c_char
) -> i32 {
    let action = unsafe { CStr::from_ptr(action_name).to_str().unwrap() };
    let args = unsafe { CStr::from_ptr(arguments_json).to_str().unwrap() };

    let result = match action {
        "myAction" => execute_my_action(args),
        _ => Err("Unknown action".to_string())
    };

    match result {
        Ok(json) => {
            unsafe { *result_ptr = CString::new(json).unwrap().into_raw(); }
            0
        }
        Err(e) => {
            let error_json = format!("{{\"error\": \"{}\"}}", e);
            unsafe { *result_ptr = CString::new(error_json).unwrap().into_raw(); }
            1
        }
    }
}
```

### aro_plugin_free

Frees memory allocated by the plugin.

```c
void aro_plugin_free(void* ptr);
```

**Parameters:**
- `ptr`: Pointer to memory previously allocated by the plugin

**Example Implementation (C):**
```c
void aro_plugin_free(void* ptr) {
    free(ptr);
}
```

**Example Implementation (Rust):**
```rust
#[no_mangle]
pub extern "C" fn aro_plugin_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}
```

**Example Implementation (Swift):**
```swift
@_cdecl("aro_plugin_free")
public func pluginFree(_ ptr: UnsafeMutableRawPointer?) {
    if let ptr = ptr {
        free(ptr)
    }
}
```

## Optional Functions

### aro_plugin_init

Called when the plugin is loaded. Use for one-time initialization.

```c
int32_t aro_plugin_init(void);
```

**Returns:**
- `0` on success
- Non-zero on initialization failure (plugin will not be loaded)

**Example:**
```c
int32_t aro_plugin_init(void) {
    // Initialize global state, connection pools, etc.
    return 0;
}
```

### aro_plugin_shutdown

Called when the plugin is unloaded. Use for cleanup.

```c
void aro_plugin_shutdown(void);
```

**Example:**
```c
void aro_plugin_shutdown(void) {
    // Close connections, free global resources
}
```

## System Object Functions

For plugins that provide system objects.

### aro_object_read

Read from a system object.

```c
int32_t aro_object_read(
    const char* object_name,
    const char* qualifier,
    const char* options_json,
    char** result_ptr
);
```

**Parameters:**
- `object_name`: System object identifier (e.g., "redis")
- `qualifier`: Object qualifier (e.g., key name)
- `options_json`: Additional options as JSON
- `result_ptr`: Output pointer for result JSON

**Returns:**
- `0` on success
- Non-zero on error

### aro_object_write

Write to a system object.

```c
int32_t aro_object_write(
    const char* object_name,
    const char* qualifier,
    const char* data_json,
    const char* options_json,
    char** result_ptr
);
```

**Parameters:**
- `object_name`: System object identifier
- `qualifier`: Object qualifier (e.g., key name)
- `data_json`: Data to write as JSON
- `options_json`: Additional options as JSON
- `result_ptr`: Output pointer for result/status JSON

### aro_object_list

List entries from an enumerable system object.

```c
int32_t aro_object_list(
    const char* object_name,
    const char* qualifier,
    const char* options_json,
    char** result_ptr
);
```

**Parameters:**
- `object_name`: System object identifier
- `qualifier`: Pattern or filter (e.g., glob pattern)
- `options_json`: Options like limit, offset
- `result_ptr`: Output pointer for JSON array of results

## JSON Argument Format

### Standard Argument Structure

Arguments are passed as a JSON object:

```json
{
  "arg1": "string value",
  "arg2": 123,
  "arg3": true,
  "arg4": ["array", "values"],
  "arg5": {"nested": "object"}
}
```

### Context Information

ARO may include context information with the prefix `_context_`:

```json
{
  "inputValue": "user data",
  "_context_requestId": "abc-123",
  "_context_userId": "user-456"
}
```

## JSON Result Format

### Success Response

```json
{
  "result": "any value",
  "metadata": {
    "optional": "additional info"
  }
}
```

Or simply the result value:

```json
"direct string result"
```

```json
{"key": "object result"}
```

```json
[1, 2, 3]
```

### Error Response

```json
{
  "error": "Error message",
  "code": "ERROR_CODE",
  "details": {
    "field": "additional context"
  }
}
```

## Error Codes

Standard error codes returned by `aro_plugin_execute`:

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error (see error JSON) |
| 2 | Invalid arguments |
| 3 | Action not found |
| 4 | Resource not available |
| 5 | Permission denied |
| 6 | Timeout |
| 7 | Internal error |

## Memory Management Rules

1. **Strings passed TO the plugin** (action_name, arguments_json):
   - Owned by ARO
   - Valid only for the duration of the call
   - Do not free or store pointers to these strings

2. **Strings returned FROM the plugin** (via result_ptr):
   - Must be heap-allocated (`malloc`, `strdup`, etc.)
   - Ownership transfers to ARO
   - ARO will call `aro_plugin_free` when done

3. **Static strings** (from aro_plugin_info):
   - May be static or leaked (never freed)
   - Must remain valid for plugin lifetime

## Thread Safety

- `aro_plugin_execute` may be called from multiple threads concurrently
- Plugins must ensure thread-safe access to shared state
- Use mutexes, atomic operations, or thread-local storage as needed

**Example (Rust with Mutex):**
```rust
use std::sync::Mutex;
use once_cell::sync::Lazy;

static SHARED_STATE: Lazy<Mutex<SharedState>> = Lazy::new(|| {
    Mutex::new(SharedState::new())
});

#[no_mangle]
pub extern "C" fn aro_plugin_execute(...) -> i32 {
    let mut state = SHARED_STATE.lock().unwrap();
    // Safe access to shared state
}
```

## Complete C Plugin Template

```c
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// Plugin metadata
static const char* PLUGIN_INFO =
    "{"
    "  \"name\": \"my-plugin\","
    "  \"version\": \"1.0.0\","
    "  \"actions\": ["
    "    {\"name\": \"myAction\", \"symbol\": \"aro_plugin_execute\"}"
    "  ]"
    "}";

// Plugin info (required)
const char* aro_plugin_info(void) {
    return PLUGIN_INFO;
}

// Plugin initialization (optional)
int32_t aro_plugin_init(void) {
    // Initialize resources
    return 0;
}

// Plugin shutdown (optional)
void aro_plugin_shutdown(void) {
    // Cleanup resources
}

// Action execution (required)
int32_t aro_plugin_execute(
    const char* action_name,
    const char* arguments_json,
    char** result_ptr
) {
    if (strcmp(action_name, "myAction") == 0) {
        // Parse arguments_json
        // Execute action logic
        // Build result JSON

        char* result = malloc(256);
        snprintf(result, 256, "{\"success\": true, \"message\": \"Hello from plugin!\"}");
        *result_ptr = result;
        return 0;
    }

    char* error = malloc(128);
    snprintf(error, 128, "{\"error\": \"Unknown action: %s\"}", action_name);
    *result_ptr = error;
    return 3;
}

// Memory cleanup (required)
void aro_plugin_free(void* ptr) {
    free(ptr);
}
```

## Complete Rust Plugin Template

```rust
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_void};

#[no_mangle]
pub extern "C" fn aro_plugin_info() -> *const c_char {
    let info = r#"{"name":"my-plugin","version":"1.0.0","actions":[{"name":"myAction"}]}"#;
    CString::new(info).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn aro_plugin_init() -> i32 {
    // Initialize
    0
}

#[no_mangle]
pub extern "C" fn aro_plugin_shutdown() {
    // Cleanup
}

#[no_mangle]
pub extern "C" fn aro_plugin_execute(
    action_name: *const c_char,
    arguments_json: *const c_char,
    result_ptr: *mut *mut c_char
) -> i32 {
    let action = unsafe { CStr::from_ptr(action_name).to_str().unwrap_or("") };
    let _args = unsafe { CStr::from_ptr(arguments_json).to_str().unwrap_or("{}") };

    let result = match action {
        "myAction" => {
            r#"{"success": true, "message": "Hello from Rust!"}"#.to_string()
        }
        _ => {
            format!(r#"{{"error": "Unknown action: {}"}}"#, action)
        }
    };

    unsafe {
        *result_ptr = CString::new(result).unwrap().into_raw();
    }

    0
}

#[no_mangle]
pub extern "C" fn aro_plugin_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { let _ = CString::from_raw(ptr); }
    }
}
```
