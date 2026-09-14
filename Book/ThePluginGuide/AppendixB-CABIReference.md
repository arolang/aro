# Appendix B: C ABI Function Reference

This appendix provides a complete reference for the C ABI functions that plugins must implement to integrate with ARO.

## Overview

ARO communicates with native plugins through a C-compatible Application Binary Interface (ABI). This design enables plugins written in any language that can produce C-compatible functions—Swift, Rust, C, C++, and others—to integrate seamlessly.

## Function Summary

| Function | Required | Purpose |
|----------|----------|---------|
| `aro_plugin_info` | **Required** | Returns plugin metadata as JSON |
| `aro_plugin_free` | **Required** | Frees memory allocated by the plugin |
| `aro_plugin_execute` | Optional | Executes actions and service calls |
| `aro_plugin_qualifier` | Optional | Executes a qualifier transformation |
| `aro_plugin_init` | Optional | One-time initialization on load |
| `aro_plugin_shutdown` | Optional | Cleanup on unload |
| `aro_plugin_on_event` | Optional | Receives subscribed events |
| `aro_plugin_register` | Optional | Forces file-scope initialisation before info is read |
| `aro_plugin_set_invoke` | Optional | Receives a callback for invoking ARO feature sets |
| `aro_object_read` | Optional | Reads from a system object |
| `aro_object_write` | Optional | Writes to a system object |
| `aro_object_list` | Optional | Lists entries from a system object |

These twelve are the complete set the runtime looks for, and the exact set
`aro build` renames when it statically links a plugin into a binary.

## Required Functions

### aro_plugin_info

Returns plugin metadata as a JSON string. **This function is required.** ARO calls it immediately after loading the plugin to discover what the plugin provides. If this function is absent, the plugin will fail to load.

```c
char* aro_plugin_info(void);
```

**Returns:**
- Pointer to a heap-allocated, null-terminated JSON string
- **Ownership transfers to ARO**, which calls `aro_plugin_free` on it as soon
  as the metadata is parsed

This is the trap in this appendix. It is natural to return a `static const
char*` — the metadata never changes — but ARO frees what it gets back, and
`free()` on a static buffer is undefined behaviour. Allocate a fresh copy on
every call (`strdup` in C, `CString::into_raw` in Rust, `strdup` in Swift).

**JSON Schema:**
```json
{
  "name": "string",
  "version": "string",
  "actions": [
    {
      "name": "string",
      "role": "own | request | response | export",
      "verbs": ["verb1", "verb2"],
      "prepositions": ["from", "to", "with", "for", "into", "as"]
    }
  ],
  "qualifiers": [
    {
      "name": "string",
      "inputTypes": ["String", "List"],
      "description": "string",
      "accepts_parameters": false
    }
  ],
  "services": [
    {
      "name": "string",
      "methods": ["method1", "method2"]
    }
  ],
  "system_objects": [
    {
      "identifier": "string",
      "capabilities": ["readable", "writable", "enumerable"],
      "description": "string"
    }
  ],
  "events": {
    "emits": ["EventName"],
    "subscribes": ["OtherEventName"]
  },
  "deprecations": [
    {
      "feature": "string",
      "message": "string",
      "since": "string",
      "remove_in": "string"
    }
  ]
}
```

The parser ignores keys it does not recognise, so every one of those spellings
matters and a typo costs you the feature silently rather than raising an error.
Three are easy to get wrong:

- `services[].methods` is a **plural array**, not a singular `method` string.
- `system_objects[]` is keyed on `identifier`, and `name` is accepted as an
  alias — which matters, because every SDK emits `name` and none emits
  `identifier` (GitLab #556). Prefer `identifier` in hand-written info JSON:
  it matches the field's name in the runtime, and it wins if both are present.
- `qualifiers[].inputTypes` is **camelCase** while `accepts_parameters` beside
  it is snake_case. That is inconsistent, and it is what the runtime reads;
  spelling it `input_types` makes the qualifier accept every type instead.

After changing metadata, confirm what actually registered with `aro actions`
and `aro actions --qualifiers`.

**Action Metadata Fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Action identifier |
| `role` | No | Semantic role: `request`, `own`, `response`, or `export` |
| `verbs` | No | Array of verbs that trigger this action (e.g., `["hash", "digest"]`) |
| `prepositions` | No | Valid prepositions: `from`, `to`, `with`, `for`, `into`, `as`, `against`, `via` |

**Qualifier Metadata Fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Qualifier identifier (plain name, no namespace prefix — the handle from `plugin.yaml` is prepended by the runtime) |
| `inputTypes` | No | Types this qualifier accepts: `String`, `Int`, `Double`, `Bool`, `List`, `Object`. Camel-cased. Omitted or misspelled means "all types" |
| `description` | No | Shown by `aro actions --qualifiers`, in editor hover, and in the MCP tools |
| `accepts_parameters` | No | Whether the qualifier accepts an inline `with { }` clause (default: `false`) |

**Action Roles:**

| Role | Data Flow | Examples |
|------|-----------|----------|
| `request` | External → Internal | Extract, Retrieve, Fetch |
| `own` | Internal → Internal | Compute, Transform, Hash |
| `response` | Internal → External | Return, Send, Log |
| `export` | Makes data available | Publish, Store, Emit |

**Top-Level Metadata Fields:**

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Plugin name |
| `version` | Yes | Plugin version string |
| `actions` | No | Array of action descriptors |
| `qualifiers` | No | Array of qualifier descriptors |
| `services` | No | Array of service descriptors |
| `system_objects` | No | Array of system object descriptors |
| `events.emits` | No | Event names this plugin emits |
| `events.subscribes` | No | Event names this plugin subscribes to (requires `aro_plugin_on_event`) |
| `deprecations` | No | List of deprecated names with replacement guidance |

**Full Example:**
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
  ],
  "qualifiers": [
    {
      "name": "sha256",
      "inputTypes": ["String"],
      "accepts_parameters": false
    },
    {
      "name": "truncate",
      "inputTypes": ["String"],
      "accepts_parameters": true
    }
  ],
  "services": [
    {
      "name": "key-store",
      "methods": ["get", "put", "rotate"]
    }
  ],
  "events": {
    "emits": ["KeyRotated"],
    "subscribes": ["ApplicationStart"]
  },
  "deprecations": [
    {
      "feature": "md5",
      "message": "Use sha256 instead",
      "since": "1.4.0",
      "remove_in": "2.0.0"
    }
  ]
}
```

This enables ARO code like:
```aro
Hash the <result: sha256> from the <password>.
Encrypt the <ciphertext> from <data> with { key: <key> }.
```

**Example Implementation (C):**
```c
static const char* PLUGIN_INFO_JSON =
    "{"
    "  \"name\": \"my-plugin\","
    "  \"version\": \"1.0.0\","
    "  \"actions\": ["
    "    {\"name\": \"myAction\", \"verbs\": [\"myaction\"],"
    "     \"role\": \"own\", \"prepositions\": [\"from\"]}"
    "  ]"
    "}";

char* aro_plugin_info(void) {
    /* strdup, not the static pointer: ARO frees what we return. */
    return strdup(PLUGIN_INFO_JSON);
}
```

**Example Implementation (Rust):**
```rust
#[no_mangle]
pub extern "C" fn aro_plugin_info() -> *mut c_char {
    const INFO: &str = r#"{
        "name": "my-plugin",
        "version": "1.0.0",
        "actions": [{"name": "myAction", "verbs": ["myaction"], "role": "own"}]
    }"#;

    // into_raw hands ownership to ARO, which frees it via aro_plugin_free.
    CString::new(INFO).unwrap().into_raw()
}
```

**Example Implementation (Swift):**
```swift
@_cdecl("aro_plugin_info")
public func pluginInfo() -> UnsafeMutablePointer<CChar> {
    let info = """
    {"name": "my-plugin", "version": "1.0.0", "actions": [...]}
    """
    return strdup(info)!
}
```

### aro_plugin_free

Frees memory allocated by the plugin. **This function is required.** ARO calls it to release any heap-allocated string returned by plugin functions.

```c
void aro_plugin_free(char* ptr);
```

**Parameters:**
- `ptr`: Pointer to memory previously allocated by the plugin

**Example Implementation (C):**
```c
void aro_plugin_free(char* ptr) {
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

### aro_plugin_execute

Executes a plugin action or service call. **This function is optional.** Implement it only if your plugin provides actions or services. If the plugin only provides qualifiers or system objects, you may omit this function.

```c
char* aro_plugin_execute(
    const char* action_name,
    const char* input_json
);
```

**Parameters:**
- `action_name`: Null-terminated string with the action name, or `"service:<method>"` for service calls (e.g., `"service:keystore"`)
- `input_json`: Null-terminated JSON string containing the full input descriptor (see [Plugin Input JSON](#plugin-input-json))

**Returns:**
- Pointer to a heap-allocated null-terminated JSON string on success or error
- ARO will call `aro_plugin_free` to release the returned string

**Service Routing:**

Services no longer have a separate ABI entry point. Instead, service method calls are routed through `aro_plugin_execute` with the `action_name` set to `"service:<method>"`:

```c
// Action call:   action_name = "Hash"
// Service call:  action_name = "service:keystore"
char* aro_plugin_execute(const char* action_name, const char* input_json) {
    if (strncmp(action_name, "service:", 8) == 0) {
        const char* method = action_name + 8;
        return handle_service_call(method, input_json);
    }
    return handle_action(action_name, input_json);
}
```

**Example Implementation (C):**
```c
char* aro_plugin_execute(const char* action_name, const char* input_json) {
    if (strcmp(action_name, "myAction") == 0) {
        // Parse input_json
        // Execute action
        // Format result
        return strdup("{\"result\": \"success\"}");
    }

    if (strncmp(action_name, "service:", 8) == 0) {
        const char* method = action_name + 8;
        // Handle service method
        return strdup("{\"ok\": true}");
    }

    return strdup("{\"error\": \"Unknown action\"}");
}
```

**Example Implementation (Rust):**
```rust
#[no_mangle]
pub extern "C" fn aro_plugin_execute(
    action_name: *const c_char,
    input_json: *const c_char
) -> *mut c_char {
    let action = unsafe { CStr::from_ptr(action_name).to_str().unwrap_or("") };
    let input = unsafe { CStr::from_ptr(input_json).to_str().unwrap_or("{}") };

    let result = if action.starts_with("service:") {
        let method = &action["service:".len()..];
        handle_service(method, input)
    } else {
        match action {
            "myAction" => execute_my_action(input),
            _ => format!(r#"{{"error": "Unknown action: {}"}}"#, action)
        }
    };

    CString::new(result).unwrap().into_raw()
}
```

### aro_plugin_qualifier

Executes a qualifier transformation. **This function is optional.** Implement it
only if `aro_plugin_info` declares qualifiers — the runtime registers a
plugin's qualifiers only when this symbol is present.

```c
char* aro_plugin_qualifier(
    const char* qualifier_name,
    const char* input_json
);
```

**Parameters:**
- `qualifier_name`: The qualifier's plain name, without the handle prefix. ARO
  code writes `<value: Hash.sha256>`; your function receives `"sha256"`.
- `input_json`: `{"value": <the value>, "type": "String", "_with": { … }}`.
  `type` is the runtime's detected type of the value; `_with` carries the
  qualifier's inline parameters and is present only for qualifiers that
  declared `accepts_parameters: true`.

**Returns:** a heap-allocated JSON string in exactly one of two shapes:

```json
{"result": "the transformed value"}
```
```json
{"error": "what went wrong"}
```

Nothing else is accepted. This is stricter than `aro_plugin_execute`, which may
return any object. A qualifier that returns the bare value, or wraps it under a
different key such as `{"value": …}`, fails with *Plugin returned neither
result nor error*; one that wraps twice, `{"result": {"result": …}}`, binds the
inner object rather than the value. Both mistakes are live in the shipped SDKs
— see GitLab #551 (Python) and #554 (Rust).

**Example Implementation (C):**
```c
char* aro_plugin_qualifier(const char* qualifier_name, const char* input_json) {
    if (strcmp(qualifier_name, "sha256") == 0) {
        char* digest = compute_sha256_of_value(input_json);   /* your code */
        char* out = malloc(strlen(digest) + 32);
        if (!out) { free(digest); return strdup("{\"error\":\"out of memory\"}"); }
        snprintf(out, strlen(digest) + 32, "{\"result\":\"%s\"}", digest);
        free(digest);
        return out;
    }
    return strdup("{\"error\": \"Unknown qualifier\"}");
}
```

### aro_plugin_init

Called once when the plugin is loaded. Use for one-time initialization such as setting up connection pools, loading configuration, or allocating global resources.

```c
void aro_plugin_init(void);
```

**Example:**
```c
void aro_plugin_init(void) {
    // Initialize global state, connection pools, etc.
}
```

### aro_plugin_shutdown

Called when the plugin is unloaded. Use for cleanup such as closing connections and freeing global resources.

```c
void aro_plugin_shutdown(void);
```

**Example:**
```c
void aro_plugin_shutdown(void) {
    // Close connections, free global resources
}
```

### aro_plugin_on_event

Called when an event that the plugin has subscribed to is emitted. The plugin declares subscriptions in the `events.subscribes` array in `aro_plugin_info`.

```c
void aro_plugin_on_event(const char* event_type, const char* data_json);
```

**Parameters:**
- `event_type`: Null-terminated string with the event name (e.g., `"UserCreated"`)
- `data_json`: Null-terminated JSON string with the event payload

**Example:**
```c
void aro_plugin_on_event(const char* event_type, const char* data_json) {
    if (strcmp(event_type, "ApplicationStart") == 0) {
        // Perform startup work triggered by the app lifecycle event
    }
}
```

To subscribe to events, declare them in `aro_plugin_info`:
```json
{
  "events": {
    "subscribes": ["ApplicationStart", "UserCreated"]
  }
}
```

## System Object Functions

For plugins that provide system objects, implement the following functions. Declare the objects in `aro_plugin_info` under `system_objects`.

### aro_object_read

Reads from a system object.

```c
char* aro_object_read(const char* identifier, const char* qualifier);
```

**Parameters:**
- `identifier`: System object identifier (e.g., `"redis"`)
- `qualifier`: Object qualifier or key (e.g., a Redis key name)

**Returns:**
- Pointer to a heap-allocated null-terminated JSON string with the result
- ARO will call `aro_plugin_free` to release the returned string

**Example:**
```c
char* aro_object_read(const char* identifier, const char* qualifier) {
    if (strcmp(identifier, "redis") == 0) {
        const char* value = redis_get(qualifier);
        char* buf = malloc(strlen(value) + 16);
        sprintf(buf, "{\"value\": \"%s\"}", value);
        return buf;
    }
    return strdup("{\"error\": \"Unknown object\"}");
}
```

### aro_object_write

Writes to a system object.

```c
char* aro_object_write(
    const char* identifier,
    const char* qualifier,
    const char* value_json
);
```

**Parameters:**
- `identifier`: System object identifier
- `qualifier`: Object qualifier or key
- `value_json`: Value to write, as a JSON string

**Returns:**
- Pointer to a heap-allocated null-terminated JSON string with the result or status
- ARO will call `aro_plugin_free` to release the returned string

**Example:**
```c
char* aro_object_write(
    const char* identifier,
    const char* qualifier,
    const char* value_json
) {
    if (strcmp(identifier, "redis") == 0) {
        int ok = redis_set(qualifier, value_json);
        return strdup(ok ? "{\"ok\": true}" : "{\"error\": \"Write failed\"}");
    }
    return strdup("{\"error\": \"Unknown object\"}");
}
```

### aro_object_list

Lists entries from an enumerable system object.

```c
char* aro_object_list(const char* pattern);
```

**Parameters:**
- `pattern`: Glob pattern or filter string (e.g., `"user:*"`)

**Returns:**
- Pointer to a heap-allocated null-terminated JSON array string with matching keys or entries
- ARO will call `aro_plugin_free` to release the returned string

**Example:**
```c
char* aro_object_list(const char* pattern) {
    // Return a JSON array of matching keys
    return strdup("[\"user:1\", \"user:2\", \"user:3\"]");
}
```

## Plugin Input JSON

When ARO calls `aro_plugin_execute`, the `input_json` parameter carries a structured descriptor that describes the ARO statement being executed.

### Input JSON Schema

```json
{
  "result": {
    "base": "result-variable-name",
    "specifiers": ["qualifier1", "qualifier2"]
  },
  "source": {
    "base": "source-variable-name",
    "specifiers": ["qualifier1"]
  },
  "preposition": "from",
  "_context": {
    "requestId": "abc-123",
    "featureSet": "listUsers",
    "businessActivity": "User API"
  },
  "_with": {
    "param1": "value1",
    "param2": 42
  }
}
```

**Input Fields:**

| Field | Description |
|-------|-------------|
| `result.base` | The base name of the result binding (left-hand side of the statement) |
| `result.specifiers` | Qualifiers applied to the result (e.g., `["sha256"]` from `<result: sha256>`) |
| `source.base` | The base name of the source object (right-hand side of the statement) |
| `source.specifiers` | Qualifiers applied to the source |
| `preposition` | The preposition used in the statement (`from`, `to`, `with`, `for`, `into`, `as`, `against`, `via`) |
| `_context.requestId` | Unique identifier for the current HTTP request, if applicable |
| `_context.featureSet` | Name of the feature set currently executing |
| `_context.businessActivity` | Business activity of the feature set |
| `_with` | Additional named parameters passed via `with` clauses |

**Example:** For the ARO statement:

```aro
Hash the <digest: sha256> from the <password>.
```

The input JSON will be:
```json
{
  "result": {
    "base": "digest",
    "specifiers": ["sha256"]
  },
  "source": {
    "base": "password",
    "specifiers": []
  },
  "preposition": "from",
  "_context": {
    "requestId": "req-789",
    "featureSet": "createUser",
    "businessActivity": "User API"
  },
  "_with": {}
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

Or simply the result value directly:

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

No ABI function returns a status code. Every function that can fail returns a
JSON string and communicates the failure through an `error` field in it. The
older three-parameter form of `aro_plugin_execute` — an out-pointer plus an
`int32_t` return — was removed; if you meet it in an older plugin, port it.

The `code` field below is an optional string in the error body, useful for
callers that want to branch on a category rather than parse a message:

| Code | Meaning |
|------|---------|
| `SUCCESS` | Operation completed successfully |
| `GENERAL_ERROR` | General error (see `error` message) |
| `INVALID_ARGUMENTS` | Arguments were malformed or missing |
| `NOT_FOUND` | Action or resource not found |
| `UNAVAILABLE` | Resource not currently available |
| `PERMISSION_DENIED` | Caller lacks required permission |
| `TIMEOUT` | Operation timed out |
| `INTERNAL_ERROR` | Unexpected internal error |

## Memory Management Rules

1. **Strings passed TO the plugin** (`action_name`, `input_json`, `identifier`, `qualifier`, etc.):
   - Owned by ARO
   - Valid only for the duration of the call
   - Do not free or store pointers to these strings

2. **Strings returned FROM the plugin** (return values of `aro_plugin_execute`, `aro_object_read`, `aro_object_write`, `aro_object_list`):
   - Must be heap-allocated (`malloc`, `strdup`, etc.)
   - Ownership transfers to ARO
   - ARO will call `aro_plugin_free` when done

3. **`aro_plugin_info` is not an exception.** Its return value is freed like
   every other. Do not return a static or otherwise non-`free()`able pointer
   from it.

## Thread Safety

- `aro_plugin_execute` may be called from multiple threads concurrently
- `aro_plugin_on_event` may also be called from different threads
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
pub extern "C" fn aro_plugin_execute(
    action_name: *const c_char,
    input_json: *const c_char
) -> *mut c_char {
    let mut state = SHARED_STATE.lock().unwrap();
    // Safe access to shared state
    todo!()
}
```

## Complete C Plugin Template

```c
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// Plugin metadata (required)
static const char* PLUGIN_INFO =
    "{"
    "  \"name\": \"my-plugin\","
    "  \"version\": \"1.0.0\","
    "  \"actions\": ["
    "    {\"name\": \"myAction\", \"verbs\": [\"myaction\"], \"role\": \"own\"}"
    "  ]"
    "}";

// Plugin info (required)
char* aro_plugin_info(void) {
    /* ARO frees what we return, so hand back a fresh copy. */
    return strdup(PLUGIN_INFO);
}

// Plugin initialization (optional)
void aro_plugin_init(void) {
    // Initialize resources
}

// Plugin shutdown (optional)
void aro_plugin_shutdown(void) {
    // Cleanup resources
}

// Event handler (optional)
void aro_plugin_on_event(const char* event_type, const char* data_json) {
    // Handle subscribed events
}

// Action/service execution (optional — only needed if plugin provides actions or services)
char* aro_plugin_execute(const char* action_name, const char* input_json) {
    if (strcmp(action_name, "myAction") == 0) {
        // Parse input_json
        // Execute action logic
        // Build result JSON

        char* result = malloc(256);
        snprintf(result, 256, "{\"success\": true, \"message\": \"Hello from plugin!\"}");
        return result;
    }

    if (strncmp(action_name, "service:", 8) == 0) {
        const char* method = action_name + 8;
        char* result = malloc(128);
        snprintf(result, 128, "{\"ok\": true, \"method\": \"%s\"}", method);
        return result;
    }

    char* error = malloc(128);
    snprintf(error, 128, "{\"error\": \"Unknown action: %s\"}", action_name);
    return error;
}

// Memory cleanup (required)
void aro_plugin_free(char* ptr) {
    free(ptr);
}
```

## Complete Rust Plugin Template

```rust
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[no_mangle]
pub extern "C" fn aro_plugin_info() -> *const c_char {
    let info = r#"{
        "name": "my-plugin",
        "version": "1.0.0",
        "actions": [{"name": "myAction", "verbs": ["myaction"], "role": "own"}]
    }"#;
    // Leak the CString so it lives for the plugin's lifetime
    CString::new(info).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn aro_plugin_init() {
    // Initialize
}

#[no_mangle]
pub extern "C" fn aro_plugin_shutdown() {
    // Cleanup
}

#[no_mangle]
pub extern "C" fn aro_plugin_on_event(
    event_type: *const c_char,
    data_json: *const c_char
) {
    let _event = unsafe { CStr::from_ptr(event_type).to_str().unwrap_or("") };
    let _data = unsafe { CStr::from_ptr(data_json).to_str().unwrap_or("{}") };
    // Handle subscribed events
}

// Optional — only implement if plugin provides actions or services
#[no_mangle]
pub extern "C" fn aro_plugin_execute(
    action_name: *const c_char,
    input_json: *const c_char
) -> *mut c_char {
    let action = unsafe { CStr::from_ptr(action_name).to_str().unwrap_or("") };
    let _input = unsafe { CStr::from_ptr(input_json).to_str().unwrap_or("{}") };

    let result = if action.starts_with("service:") {
        let method = &action["service:".len()..];
        format!(r#"{{"ok": true, "method": "{}"}}"#, method)
    } else {
        match action {
            "myAction" => r#"{"success": true, "message": "Hello from Rust!"}"#.to_string(),
            _ => format!(r#"{{"error": "Unknown action: {}"}}"#, action),
        }
    };

    CString::new(result).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn aro_plugin_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { let _ = CString::from_raw(ptr); }
    }
}
```
