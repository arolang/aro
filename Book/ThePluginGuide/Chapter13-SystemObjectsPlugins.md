# Chapter 12: System Objects Plugins

> *"The best abstractions feel inevitable—as if the system could work no other way."*
> — Rob Pike

Throughout this book, we've seen how plugins extend ARO with new actions. But there's another dimension to extensibility that we haven't yet explored: **system objects**. When you write `Log "Hello" to the <console>.` or `Read the <config> from the <file: "settings.yaml">.`, you're interacting with system objects—built-in I/O targets that ARO provides. This chapter reveals how plugins can contribute their own system objects, enabling syntax like `Read the <session> from the <redis: "user:123">.` or `Write <document> to the <elasticsearch: "products">.`

## 12.1 Understanding System Objects

Before we can extend the system objects mechanism, we need to understand what system objects are and how they work within ARO's I/O architecture.

### The Source/Sink Model

ARO classifies I/O targets into three categories based on their capabilities:

**Sources** are objects you read *from*:
```aro
Read the <input> from the <stdin>.
Get the <api-key> from the <env: "API_KEY">.
Extract the <id> from the <pathParameters: id>.
```

**Sinks** are objects you write *to*:
```aro
Log "Starting..." to the <console>.
Write <data> to the <file: "./output.json">.
Send <message> to the <connection>.
```

**Bidirectional** objects support both operations:
```aro
(* File: read and write *)
Read the <config> from the <file: "./settings.yaml">.
Write <updated-config> to the <file: "./settings.yaml">.

(* Socket connection: send and receive *)
Send <request> to the <connection>.
Extract the <response> from the <connection>.
```

### Built-in System Objects

ARO provides these system objects out of the box:

| Object | Type | Description |
|--------|------|-------------|
| `console` | Sink | Standard output stream |
| `stderr` | Sink | Standard error stream |
| `stdin` | Source | Standard input stream |
| `env` | Source | Environment variables |
| `file` | Bidirectional | File system access |
| `request` | Source | HTTP request context |
| `pathParameters` | Source | URL path parameters |
| `queryParameters` | Source | URL query parameters |
| `headers` | Source | HTTP headers |
| `body` | Source | Request body |
| `connection` | Bidirectional | Socket connection |
| `event` | Source | Event payload |

### The Qualifier Pattern

System objects often use **qualifiers** to specify details:

```aro
(* File path as qualifier *)
Read the <data> from the <file: "./data.json">.

(* Environment variable name as qualifier *)
Get the <port> from the <env: "PORT">.

(* Property path as qualifier *)
Extract the <name> from the <user: name>.
```

This pattern is central to how custom system objects work. When you create a Redis plugin, the key becomes the qualifier:

```aro
Read the <session> from the <redis: "session:user:123">.
```

## 12.2 The System Objects Protocol

Plugins expose system objects by implementing a specific protocol. This section covers the architecture that makes custom system objects possible.

### Registration Mechanism

When a plugin wants to provide a system object, it declares the capability in its `plugin.yaml` manifest:

```yaml
name: redis-plugin
version: 1.0.0
description: Redis system object for ARO

provides:
  - type: rust-plugin
    path: src/
    system-objects:
      - name: redis
        capabilities: [readable, writable]
        config:
          connection-url: "REDIS_URL"
```

The `system-objects` section tells ARO:
- **name**: The identifier used in ARO code (`<redis: ...>`)
- **capabilities**: What operations are supported
- **config**: Configuration options (environment variables, defaults)

### The C ABI Interface

System objects use the same C ABI as actions, with additional functions for read/write operations:

```c
// Required: Plugin initialization
const char* aro_plugin_info(void);

// System object read operation
// Returns JSON result or error
int32_t aro_object_read(
    const char* object_name,   // e.g., "redis"
    const char* qualifier,     // e.g., "session:user:123"
    const char* options_json,  // Additional options
    char** result_ptr          // Output: JSON result
);

// System object write operation
// Writes data to the system object
int32_t aro_object_write(
    const char* object_name,   // e.g., "redis"
    const char* qualifier,     // e.g., "session:user:123"
    const char* data_json,     // Data to write
    const char* options_json,  // Additional options
    char** result_ptr          // Output: success/error JSON
);

// Memory cleanup
void aro_plugin_free(void* ptr);
```

### Capability Declarations

The `capabilities` field in the manifest controls which ARO actions can use the system object:

| Capability | Supported Actions |
|------------|-------------------|
| `readable` | `<Read>`, `<Get>`, `<Extract>` |
| `writable` | `<Write>`, `<Log>`, `<Send>`, `<Append>` |
| `enumerable` | `<List>` (collection iteration) |
| `watchable` | `<Watch>` (change notifications) |

A Redis plugin might declare `readable, writable, enumerable`:
- **readable**: Get keys
- **writable**: Set keys
- **enumerable**: Scan/list keys matching a pattern

## 12.3 Building a Redis Plugin

Let's build a complete Redis plugin in Rust that exposes a `<redis>` system object. This example demonstrates all the concepts we've discussed.

### Project Structure

```
plugin-redis/
├── plugin.yaml
├── Cargo.toml
└── src/
    └── lib.rs
```

### The Manifest

```yaml
# plugin.yaml
name: plugin-redis
version: 1.0.0
description: Redis system object for ARO
author: ARO Community
license: MIT

aro-version: ">=0.9.0"

provides:
  - type: rust-plugin
    path: src/
    build:
      cargo-target: cdylib
    system-objects:
      - name: redis
        capabilities: [readable, writable, enumerable]
        config:
          connection-url: "REDIS_URL"
          default-url: "redis://127.0.0.1:6379"
```

### The Cargo Configuration

```toml
# Cargo.toml
[package]
name = "plugin-redis"
version = "1.0.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
redis = { version = "0.24", features = ["tokio-comp"] }
tokio = { version = "1", features = ["rt-multi-thread"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
once_cell = "1.18"
```

### The Implementation

```rust
// src/lib.rs
use redis::{Client, Commands, Connection};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::Mutex;
use once_cell::sync::Lazy;

// Global Redis connection pool
static REDIS_CONNECTION: Lazy<Mutex<Option<Connection>>> = Lazy::new(|| Mutex::new(None));

/// Initialize the connection lazily
fn get_connection() -> Result<Connection, String> {
    let mut conn_guard = REDIS_CONNECTION.lock().unwrap();

    if conn_guard.is_none() {
        let url = std::env::var("REDIS_URL")
            .unwrap_or_else(|_| "redis://127.0.0.1:6379".to_string());

        let client = Client::open(url.as_str())
            .map_err(|e| format!("Failed to create Redis client: {}", e))?;

        let conn = client.get_connection()
            .map_err(|e| format!("Failed to connect to Redis: {}", e))?;

        *conn_guard = Some(conn);
    }

    // Clone the connection for use
    let url = std::env::var("REDIS_URL")
        .unwrap_or_else(|_| "redis://127.0.0.1:6379".to_string());
    let client = Client::open(url.as_str())
        .map_err(|e| format!("Failed to create Redis client: {}", e))?;
    client.get_connection()
        .map_err(|e| format!("Failed to connect to Redis: {}", e))
}

// ============================================================
// Plugin Information
// ============================================================

#[no_mangle]
pub extern "C" fn aro_plugin_info() -> *const c_char {
    let info = json!({
        "name": "plugin-redis",
        "version": "1.0.0",
        "system_objects": [
            {
                "name": "redis",
                "capabilities": ["readable", "writable", "enumerable"]
            }
        ]
    });

    let json_str = serde_json::to_string(&info).unwrap();
    CString::new(json_str).unwrap().into_raw()
}

// ============================================================
// System Object: Read
// ============================================================

/// Read from Redis
/// Qualifier is the Redis key
#[no_mangle]
pub extern "C" fn aro_object_read(
    object_name: *const c_char,
    qualifier: *const c_char,
    options_json: *const c_char,
    result_ptr: *mut *mut c_char
) -> i32 {
    let name = unsafe { CStr::from_ptr(object_name).to_str().unwrap_or("") };
    let key = unsafe { CStr::from_ptr(qualifier).to_str().unwrap_or("") };
    let options_str = unsafe { CStr::from_ptr(options_json).to_str().unwrap_or("{}") };

    if name != "redis" {
        return set_error(result_ptr, "Unknown system object");
    }

    // Parse options
    let options: Value = serde_json::from_str(options_str).unwrap_or(json!({}));
    let data_type = options.get("type").and_then(|v| v.as_str()).unwrap_or("string");

    // Get connection
    let mut conn = match get_connection() {
        Ok(c) => c,
        Err(e) => return set_error(result_ptr, &e)
    };

    // Read based on type
    let result = match data_type {
        "string" => read_string(&mut conn, key),
        "hash" => read_hash(&mut conn, key),
        "list" => read_list(&mut conn, key),
        "set" => read_set(&mut conn, key),
        _ => Err(format!("Unsupported Redis type: {}", data_type))
    };

    match result {
        Ok(value) => set_result(result_ptr, &value),
        Err(e) => set_error(result_ptr, &e)
    }
}

fn read_string(conn: &mut Connection, key: &str) -> Result<Value, String> {
    let value: Option<String> = conn.get(key)
        .map_err(|e| format!("Redis GET failed: {}", e))?;

    match value {
        Some(v) => {
            // Try to parse as JSON, fall back to string
            if let Ok(parsed) = serde_json::from_str::<Value>(&v) {
                Ok(parsed)
            } else {
                Ok(json!(v))
            }
        }
        None => Ok(Value::Null)
    }
}

fn read_hash(conn: &mut Connection, key: &str) -> Result<Value, String> {
    let hash: std::collections::HashMap<String, String> = conn.hgetall(key)
        .map_err(|e| format!("Redis HGETALL failed: {}", e))?;

    // Convert to JSON object
    let obj: serde_json::Map<String, Value> = hash.into_iter()
        .map(|(k, v)| {
            let parsed = serde_json::from_str::<Value>(&v).unwrap_or(json!(v));
            (k, parsed)
        })
        .collect();

    Ok(Value::Object(obj))
}

fn read_list(conn: &mut Connection, key: &str) -> Result<Value, String> {
    let list: Vec<String> = conn.lrange(key, 0, -1)
        .map_err(|e| format!("Redis LRANGE failed: {}", e))?;

    let items: Vec<Value> = list.into_iter()
        .map(|v| serde_json::from_str::<Value>(&v).unwrap_or(json!(v)))
        .collect();

    Ok(Value::Array(items))
}

fn read_set(conn: &mut Connection, key: &str) -> Result<Value, String> {
    let members: std::collections::HashSet<String> = conn.smembers(key)
        .map_err(|e| format!("Redis SMEMBERS failed: {}", e))?;

    let items: Vec<Value> = members.into_iter()
        .map(|v| serde_json::from_str::<Value>(&v).unwrap_or(json!(v)))
        .collect();

    Ok(Value::Array(items))
}

// ============================================================
// System Object: Write
// ============================================================

/// Write to Redis
/// Qualifier is the Redis key
#[no_mangle]
pub extern "C" fn aro_object_write(
    object_name: *const c_char,
    qualifier: *const c_char,
    data_json: *const c_char,
    options_json: *const c_char,
    result_ptr: *mut *mut c_char
) -> i32 {
    let name = unsafe { CStr::from_ptr(object_name).to_str().unwrap_or("") };
    let key = unsafe { CStr::from_ptr(qualifier).to_str().unwrap_or("") };
    let data_str = unsafe { CStr::from_ptr(data_json).to_str().unwrap_or("null") };
    let options_str = unsafe { CStr::from_ptr(options_json).to_str().unwrap_or("{}") };

    if name != "redis" {
        return set_error(result_ptr, "Unknown system object");
    }

    // Parse data and options
    let data: Value = serde_json::from_str(data_str).unwrap_or(json!(data_str));
    let options: Value = serde_json::from_str(options_str).unwrap_or(json!({}));

    // Get optional TTL
    let ttl: Option<u64> = options.get("ttl").and_then(|v| v.as_u64());
    let data_type = options.get("type").and_then(|v| v.as_str()).unwrap_or("auto");

    // Get connection
    let mut conn = match get_connection() {
        Ok(c) => c,
        Err(e) => return set_error(result_ptr, &e)
    };

    // Write based on type
    let result = match data_type {
        "hash" => write_hash(&mut conn, key, &data, ttl),
        "list" => write_list(&mut conn, key, &data, ttl),
        "set" => write_set(&mut conn, key, &data, ttl),
        _ => write_string(&mut conn, key, &data, ttl)  // "auto" or "string"
    };

    match result {
        Ok(()) => set_result(result_ptr, &json!({"success": true, "key": key})),
        Err(e) => set_error(result_ptr, &e)
    }
}

fn write_string(conn: &mut Connection, key: &str, data: &Value, ttl: Option<u64>) -> Result<(), String> {
    let value = if data.is_string() {
        data.as_str().unwrap().to_string()
    } else {
        serde_json::to_string(data).map_err(|e| format!("JSON serialization failed: {}", e))?
    };

    if let Some(seconds) = ttl {
        let _: () = conn.set_ex(key, &value, seconds)
            .map_err(|e| format!("Redis SETEX failed: {}", e))?;
    } else {
        let _: () = conn.set(key, &value)
            .map_err(|e| format!("Redis SET failed: {}", e))?;
    }

    Ok(())
}

fn write_hash(conn: &mut Connection, key: &str, data: &Value, ttl: Option<u64>) -> Result<(), String> {
    let obj = data.as_object()
        .ok_or("Hash data must be an object")?;

    // Delete existing key and write new hash
    let _: () = conn.del(key)
        .map_err(|e| format!("Redis DEL failed: {}", e))?;

    for (field, value) in obj {
        let v = if value.is_string() {
            value.as_str().unwrap().to_string()
        } else {
            serde_json::to_string(value).unwrap()
        };
        let _: () = conn.hset(key, field, &v)
            .map_err(|e| format!("Redis HSET failed: {}", e))?;
    }

    if let Some(seconds) = ttl {
        let _: () = conn.expire(key, seconds as i64)
            .map_err(|e| format!("Redis EXPIRE failed: {}", e))?;
    }

    Ok(())
}

fn write_list(conn: &mut Connection, key: &str, data: &Value, ttl: Option<u64>) -> Result<(), String> {
    let arr = data.as_array()
        .ok_or("List data must be an array")?;

    // Delete existing and push new items
    let _: () = conn.del(key)
        .map_err(|e| format!("Redis DEL failed: {}", e))?;

    for item in arr {
        let v = if item.is_string() {
            item.as_str().unwrap().to_string()
        } else {
            serde_json::to_string(item).unwrap()
        };
        let _: () = conn.rpush(key, &v)
            .map_err(|e| format!("Redis RPUSH failed: {}", e))?;
    }

    if let Some(seconds) = ttl {
        let _: () = conn.expire(key, seconds as i64)
            .map_err(|e| format!("Redis EXPIRE failed: {}", e))?;
    }

    Ok(())
}

fn write_set(conn: &mut Connection, key: &str, data: &Value, ttl: Option<u64>) -> Result<(), String> {
    let arr = data.as_array()
        .ok_or("Set data must be an array")?;

    // Delete existing and add new members
    let _: () = conn.del(key)
        .map_err(|e| format!("Redis DEL failed: {}", e))?;

    for item in arr {
        let v = if item.is_string() {
            item.as_str().unwrap().to_string()
        } else {
            serde_json::to_string(item).unwrap()
        };
        let _: () = conn.sadd(key, &v)
            .map_err(|e| format!("Redis SADD failed: {}", e))?;
    }

    if let Some(seconds) = ttl {
        let _: () = conn.expire(key, seconds as i64)
            .map_err(|e| format!("Redis EXPIRE failed: {}", e))?;
    }

    Ok(())
}

// ============================================================
// Enumerable: List Keys
// ============================================================

/// List keys matching a pattern
/// Qualifier is the glob pattern
#[no_mangle]
pub extern "C" fn aro_object_list(
    object_name: *const c_char,
    qualifier: *const c_char,
    options_json: *const c_char,
    result_ptr: *mut *mut c_char
) -> i32 {
    let name = unsafe { CStr::from_ptr(object_name).to_str().unwrap_or("") };
    let pattern = unsafe { CStr::from_ptr(qualifier).to_str().unwrap_or("*") };
    let options_str = unsafe { CStr::from_ptr(options_json).to_str().unwrap_or("{}") };

    if name != "redis" {
        return set_error(result_ptr, "Unknown system object");
    }

    // Parse options
    let options: Value = serde_json::from_str(options_str).unwrap_or(json!({}));
    let limit: usize = options.get("limit").and_then(|v| v.as_u64()).unwrap_or(100) as usize;

    // Get connection
    let mut conn = match get_connection() {
        Ok(c) => c,
        Err(e) => return set_error(result_ptr, &e)
    };

    // Scan keys
    let keys: Vec<String> = redis::cmd("SCAN")
        .cursor_arg(0)
        .arg("MATCH")
        .arg(pattern)
        .arg("COUNT")
        .arg(limit)
        .query::<(u64, Vec<String>)>(&mut conn)
        .map(|(_, keys)| keys)
        .unwrap_or_default();

    set_result(result_ptr, &json!(keys))
}

// ============================================================
// Helper Functions
// ============================================================

fn set_result(result_ptr: *mut *mut c_char, value: &Value) -> i32 {
    let json_str = serde_json::to_string(value).unwrap();
    unsafe {
        *result_ptr = CString::new(json_str).unwrap().into_raw();
    }
    0
}

fn set_error(result_ptr: *mut *mut c_char, message: &str) -> i32 {
    let error = json!({"error": message});
    let json_str = serde_json::to_string(&error).unwrap();
    unsafe {
        *result_ptr = CString::new(json_str).unwrap().into_raw();
    }
    1
}

#[no_mangle]
pub extern "C" fn aro_plugin_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}
```

### Using the Redis Plugin in ARO

Once installed, the Redis plugin enables natural syntax for cache operations:

```aro
(Application-Start: Session Manager) {
    Log "Session Manager starting..." to the <console>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(createSession: Session API) {
    Extract the <user-id> from the <body: userId>.

    (* Generate session data *)
    Create the <session-id> with <uuid>.
    Create the <session> with {
        userId: <user-id>,
        createdAt: <now>,
        expiresAt: <now + 3600>
    }.

    (* Store in Redis with 1 hour TTL *)
    Write <session> to the <redis: "session:" ++ <session-id>> with { ttl: 3600 }.

    Return a <Created: status> with { sessionId: <session-id> }.
}

(getSession: Session API) {
    Extract the <session-id> from the <pathParameters: id>.

    (* Read from Redis *)
    Read the <session> from the <redis: "session:" ++ <session-id>>.

    Return an <OK: status> with <session>.
}

(deleteSession: Session API) {
    Extract the <session-id> from the <pathParameters: id>.

    (* Delete by writing null *)
    Write null to the <redis: "session:" ++ <session-id>>.

    Return a <NoContent: status> for the <deletion>.
}
```

## 12.4 Building an Elasticsearch Plugin

Elasticsearch makes an excellent companion to our Redis example. While Redis handles ephemeral data like sessions and caches, Elasticsearch excels at searchable document storage. Let's build a plugin that exposes `<elasticsearch>` as a system object.

### Project Structure

```
plugin-elasticsearch/
├── plugin.yaml
├── Cargo.toml
└── src/
    └── lib.rs
```

### The Manifest

```yaml
# plugin.yaml
name: plugin-elasticsearch
version: 1.0.0
description: Elasticsearch system object for ARO
author: ARO Community
license: MIT

aro-version: ">=0.9.0"

provides:
  - type: rust-plugin
    path: src/
    build:
      cargo-target: cdylib
    system-objects:
      - name: elasticsearch
        capabilities: [readable, writable, enumerable]
        config:
          connection-url: "ELASTICSEARCH_URL"
          default-url: "http://localhost:9200"
```

### The Cargo Configuration

```toml
# Cargo.toml
[package]
name = "plugin-elasticsearch"
version = "1.0.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
reqwest = { version = "0.11", features = ["blocking", "json"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
```

### The Implementation

```rust
// src/lib.rs
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

fn get_base_url() -> String {
    std::env::var("ELASTICSEARCH_URL")
        .unwrap_or_else(|_| "http://localhost:9200".to_string())
}

fn client() -> Client {
    Client::new()
}

// ============================================================
// Plugin Information
// ============================================================

#[no_mangle]
pub extern "C" fn aro_plugin_info() -> *const c_char {
    let info = json!({
        "name": "plugin-elasticsearch",
        "version": "1.0.0",
        "system_objects": [
            {
                "name": "elasticsearch",
                "capabilities": ["readable", "writable", "enumerable"]
            }
        ]
    });

    let json_str = serde_json::to_string(&info).unwrap();
    CString::new(json_str).unwrap().into_raw()
}

// ============================================================
// System Object: Read
// ============================================================

/// Read from Elasticsearch
/// Qualifier format: "index/document_id" or "index" (for search)
#[no_mangle]
pub extern "C" fn aro_object_read(
    object_name: *const c_char,
    qualifier: *const c_char,
    options_json: *const c_char,
    result_ptr: *mut *mut c_char
) -> i32 {
    let name = unsafe { CStr::from_ptr(object_name).to_str().unwrap_or("") };
    let qualifier_str = unsafe { CStr::from_ptr(qualifier).to_str().unwrap_or("") };
    let options_str = unsafe { CStr::from_ptr(options_json).to_str().unwrap_or("{}") };

    if name != "elasticsearch" {
        return set_error(result_ptr, "Unknown system object");
    }

    let options: Value = serde_json::from_str(options_str).unwrap_or(json!({}));

    // Parse qualifier: "index/id" or "index"
    let parts: Vec<&str> = qualifier_str.splitn(2, '/').collect();
    let index = parts[0];
    let doc_id = parts.get(1).copied();

    if let Some(id) = doc_id {
        // Get specific document
        read_document(index, id, result_ptr)
    } else if let Some(query) = options.get("query") {
        // Search with query
        search_documents(index, query, &options, result_ptr)
    } else {
        // List all documents (simple match_all)
        search_documents(index, &json!({"match_all": {}}), &options, result_ptr)
    }
}

fn read_document(index: &str, id: &str, result_ptr: *mut *mut c_char) -> i32 {
    let url = format!("{}/{}/_doc/{}", get_base_url(), index, id);

    match client().get(&url).send() {
        Ok(response) => {
            if response.status().is_success() {
                match response.json::<Value>() {
                    Ok(body) => {
                        // Return the _source field
                        let source = body.get("_source").cloned().unwrap_or(Value::Null);
                        set_result(result_ptr, &source)
                    }
                    Err(e) => set_error(result_ptr, &format!("Failed to parse response: {}", e))
                }
            } else if response.status().as_u16() == 404 {
                set_result(result_ptr, &Value::Null)
            } else {
                set_error(result_ptr, &format!("Elasticsearch error: {}", response.status()))
            }
        }
        Err(e) => set_error(result_ptr, &format!("Request failed: {}", e))
    }
}

fn search_documents(index: &str, query: &Value, options: &Value, result_ptr: *mut *mut c_char) -> i32 {
    let url = format!("{}/{}/_search", get_base_url(), index);

    let size = options.get("limit").and_then(|v| v.as_u64()).unwrap_or(10);
    let from = options.get("offset").and_then(|v| v.as_u64()).unwrap_or(0);

    let search_body = json!({
        "query": query,
        "size": size,
        "from": from
    });

    match client().post(&url).json(&search_body).send() {
        Ok(response) => {
            if response.status().is_success() {
                match response.json::<Value>() {
                    Ok(body) => {
                        // Extract hits
                        let hits = body.get("hits")
                            .and_then(|h| h.get("hits"))
                            .and_then(|h| h.as_array())
                            .map(|arr| {
                                arr.iter()
                                    .filter_map(|hit| {
                                        let mut doc = hit.get("_source")?.clone();
                                        if let Some(obj) = doc.as_object_mut() {
                                            obj.insert("_id".to_string(),
                                                hit.get("_id").cloned().unwrap_or(Value::Null));
                                        }
                                        Some(doc)
                                    })
                                    .collect::<Vec<_>>()
                            })
                            .unwrap_or_default();

                        let total = body.get("hits")
                            .and_then(|h| h.get("total"))
                            .and_then(|t| t.get("value"))
                            .and_then(|v| v.as_u64())
                            .unwrap_or(0);

                        set_result(result_ptr, &json!({
                            "documents": hits,
                            "total": total
                        }))
                    }
                    Err(e) => set_error(result_ptr, &format!("Failed to parse response: {}", e))
                }
            } else {
                set_error(result_ptr, &format!("Elasticsearch error: {}", response.status()))
            }
        }
        Err(e) => set_error(result_ptr, &format!("Request failed: {}", e))
    }
}

// ============================================================
// System Object: Write
// ============================================================

/// Write to Elasticsearch
/// Qualifier format: "index/document_id" or "index" (auto-generated ID)
#[no_mangle]
pub extern "C" fn aro_object_write(
    object_name: *const c_char,
    qualifier: *const c_char,
    data_json: *const c_char,
    options_json: *const c_char,
    result_ptr: *mut *mut c_char
) -> i32 {
    let name = unsafe { CStr::from_ptr(object_name).to_str().unwrap_or("") };
    let qualifier_str = unsafe { CStr::from_ptr(qualifier).to_str().unwrap_or("") };
    let data_str = unsafe { CStr::from_ptr(data_json).to_str().unwrap_or("null") };

    if name != "elasticsearch" {
        return set_error(result_ptr, "Unknown system object");
    }

    let data: Value = match serde_json::from_str(data_str) {
        Ok(v) => v,
        Err(e) => return set_error(result_ptr, &format!("Invalid JSON: {}", e))
    };

    // Parse qualifier: "index/id" or "index"
    let parts: Vec<&str> = qualifier_str.splitn(2, '/').collect();
    let index = parts[0];
    let doc_id = parts.get(1).copied();

    // Handle delete (null data)
    if data.is_null() {
        if let Some(id) = doc_id {
            return delete_document(index, id, result_ptr);
        } else {
            return set_error(result_ptr, "Document ID required for deletion");
        }
    }

    // Index or update document
    if let Some(id) = doc_id {
        index_document(index, Some(id), &data, result_ptr)
    } else {
        index_document(index, None, &data, result_ptr)
    }
}

fn index_document(index: &str, id: Option<&str>, data: &Value, result_ptr: *mut *mut c_char) -> i32 {
    let url = match id {
        Some(doc_id) => format!("{}/{}/_doc/{}", get_base_url(), index, doc_id),
        None => format!("{}/{}/_doc", get_base_url(), index)
    };

    let method = if id.is_some() { "PUT" } else { "POST" };

    let request = if method == "PUT" {
        client().put(&url)
    } else {
        client().post(&url)
    };

    match request.json(data).send() {
        Ok(response) => {
            if response.status().is_success() {
                match response.json::<Value>() {
                    Ok(body) => {
                        set_result(result_ptr, &json!({
                            "success": true,
                            "_id": body.get("_id"),
                            "_index": body.get("_index"),
                            "result": body.get("result")
                        }))
                    }
                    Err(e) => set_error(result_ptr, &format!("Failed to parse response: {}", e))
                }
            } else {
                set_error(result_ptr, &format!("Elasticsearch error: {}", response.status()))
            }
        }
        Err(e) => set_error(result_ptr, &format!("Request failed: {}", e))
    }
}

fn delete_document(index: &str, id: &str, result_ptr: *mut *mut c_char) -> i32 {
    let url = format!("{}/{}/_doc/{}", get_base_url(), index, id);

    match client().delete(&url).send() {
        Ok(response) => {
            if response.status().is_success() || response.status().as_u16() == 404 {
                set_result(result_ptr, &json!({
                    "success": true,
                    "deleted": response.status().is_success()
                }))
            } else {
                set_error(result_ptr, &format!("Elasticsearch error: {}", response.status()))
            }
        }
        Err(e) => set_error(result_ptr, &format!("Request failed: {}", e))
    }
}

// ============================================================
// Enumerable: List Indices
// ============================================================

#[no_mangle]
pub extern "C" fn aro_object_list(
    object_name: *const c_char,
    qualifier: *const c_char,
    options_json: *const c_char,
    result_ptr: *mut *mut c_char
) -> i32 {
    let name = unsafe { CStr::from_ptr(object_name).to_str().unwrap_or("") };
    let pattern = unsafe { CStr::from_ptr(qualifier).to_str().unwrap_or("*") };

    if name != "elasticsearch" {
        return set_error(result_ptr, "Unknown system object");
    }

    let url = format!("{}/_cat/indices/{}?format=json", get_base_url(), pattern);

    match client().get(&url).send() {
        Ok(response) => {
            if response.status().is_success() {
                match response.json::<Vec<Value>>() {
                    Ok(indices) => {
                        let names: Vec<String> = indices.iter()
                            .filter_map(|idx| idx.get("index").and_then(|i| i.as_str()))
                            .map(|s| s.to_string())
                            .collect();
                        set_result(result_ptr, &json!(names))
                    }
                    Err(e) => set_error(result_ptr, &format!("Failed to parse response: {}", e))
                }
            } else {
                set_error(result_ptr, &format!("Elasticsearch error: {}", response.status()))
            }
        }
        Err(e) => set_error(result_ptr, &format!("Request failed: {}", e))
    }
}

// ============================================================
// Helper Functions
// ============================================================

fn set_result(result_ptr: *mut *mut c_char, value: &Value) -> i32 {
    let json_str = serde_json::to_string(value).unwrap();
    unsafe {
        *result_ptr = CString::new(json_str).unwrap().into_raw();
    }
    0
}

fn set_error(result_ptr: *mut *mut c_char, message: &str) -> i32 {
    let error = json!({"error": message});
    let json_str = serde_json::to_string(&error).unwrap();
    unsafe {
        *result_ptr = CString::new(json_str).unwrap().into_raw();
    }
    1
}

#[no_mangle]
pub extern "C" fn aro_plugin_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}
```

### Using Elasticsearch in ARO

The plugin enables powerful document operations with clean syntax:

```aro
(Application-Start: Product Catalog) {
    Log "Product Catalog starting..." to the <console>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(createProduct: Products API) {
    Extract the <product-data> from the <body>.

    (* Index the product - Elasticsearch generates ID *)
    Write <product-data> to the <elasticsearch: "products">.

    Return a <Created: status> with <product-data>.
}

(getProduct: Products API) {
    Extract the <id> from the <pathParameters: id>.

    (* Fetch specific document *)
    Read the <product> from the <elasticsearch: "products/" ++ <id>>.

    Return an <OK: status> with <product>.
}

(searchProducts: Products API) {
    Extract the <query> from the <queryParameters: q>.
    Extract the <category> from the <queryParameters: category>.

    (* Build search query *)
    Create the <search-query> with {
        bool: {
            must: [
                { match: { name: <query> } }
            ],
            filter: [
                { term: { category: <category> } }
            ]
        }
    }.

    (* Search with query and pagination *)
    Read the <results> from the <elasticsearch: "products"> with {
        query: <search-query>,
        limit: 20,
        offset: 0
    }.

    Return an <OK: status> with <results>.
}

(updateProduct: Products API) {
    Extract the <id> from the <pathParameters: id>.
    Extract the <update-data> from the <body>.

    (* Update by writing to specific ID *)
    Write <update-data> to the <elasticsearch: "products/" ++ <id>>.

    Return an <OK: status> with <update-data>.
}

(deleteProduct: Products API) {
    Extract the <id> from the <pathParameters: id>.

    (* Delete by writing null *)
    Write null to the <elasticsearch: "products/" ++ <id>>.

    Return a <NoContent: status> for the <deletion>.
}
```

## 12.5 Design Patterns for System Objects

Building effective system object plugins requires more than just implementing the protocol. This section covers patterns that make system objects feel native to ARO.

### The Qualifier Convention

System objects use qualifiers consistently. Follow these conventions:

**Path-based addressing** (hierarchical resources):
```aro
(* File system: path *)
Read the <data> from the <file: "./data/users.json">.

(* Elasticsearch: index/document *)
Read the <doc> from the <elasticsearch: "products/abc123">.

(* S3: bucket/key *)
Read the <object> from the <s3: "my-bucket/images/logo.png">.
```

**Key-based addressing** (flat key-value stores):
```aro
(* Redis: key *)
Read the <session> from the <redis: "session:user:123">.

(* Memcached: key *)
Read the <cached> from the <memcached: "api:response:xyz">.
```

**Query-based addressing** (databases):
```aro
(* PostgreSQL: table or query *)
Read the <users> from the <postgres: "users">.
Read the <active-users> from the <postgres: "SELECT * FROM users WHERE active">.
```

### Options for Fine-Grained Control

Use the `with { ... }` syntax for parameters that don't fit in qualifiers:

```aro
(* TTL for cache entries *)
Write <session> to the <redis: "session:123"> with { ttl: 3600 }.

(* Query parameters for search *)
Read the <results> from the <elasticsearch: "products"> with {
    query: { match: { name: "widget" } },
    limit: 10,
    offset: 0
}.

(* Consistency level for distributed stores *)
Read the <data> from the <cassandra: "users/123"> with {
    consistency: "quorum"
}.
```

### Error Handling Philosophy

System objects follow ARO's error philosophy: **the code is the error message**. When a read fails, ARO returns a clear description:

```
Cannot read the <session> from the <redis: "session:invalid">.
  Redis connection refused: Connection refused (os error 111)
```

Your plugin should provide meaningful error messages:

```rust
// Good: specific, actionable error
Err(format!("Redis connection failed at {}: {}", url, e))

// Bad: generic error
Err("Operation failed".to_string())
```

### Connection Management

System objects should manage connections efficiently:

**Lazy initialization**: Don't connect until first use
```rust
static CONNECTION: Lazy<Mutex<Option<Connection>>> = Lazy::new(|| Mutex::new(None));

fn get_connection() -> Result<Connection, Error> {
    let mut guard = CONNECTION.lock().unwrap();
    if guard.is_none() {
        *guard = Some(establish_connection()?);
    }
    // Return a connection from pool or create new one
}
```

**Connection pooling**: For high-throughput scenarios, use connection pools
```rust
static POOL: Lazy<Pool<PostgresConnectionManager>> = Lazy::new(|| {
    let manager = PostgresConnectionManager::new(config);
    Pool::builder().max_size(10).build(manager).unwrap()
});
```

**Graceful shutdown**: Implement cleanup when the plugin unloads
```rust
#[no_mangle]
pub extern "C" fn aro_plugin_shutdown() {
    // Close connections, flush buffers
    if let Ok(mut guard) = CONNECTION.lock() {
        if let Some(conn) = guard.take() {
            let _ = conn.close();
        }
    }
}
```

## 12.6 Testing System Object Plugins

System object plugins require careful testing across multiple dimensions.

### Unit Testing the C Interface

Test each function in isolation:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_plugin_info() {
        let info_ptr = aro_plugin_info();
        let info_str = unsafe { CStr::from_ptr(info_ptr).to_str().unwrap() };
        let info: Value = serde_json::from_str(info_str).unwrap();

        assert_eq!(info["name"], "plugin-redis");
        assert!(info["system_objects"][0]["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c == "readable"));

        // Clean up
        aro_plugin_free(info_ptr as *mut c_char);
    }

    #[test]
    fn test_read_nonexistent_key() {
        // Requires running Redis
        let object = CString::new("redis").unwrap();
        let qualifier = CString::new("nonexistent:key:12345").unwrap();
        let options = CString::new("{}").unwrap();
        let mut result: *mut c_char = std::ptr::null_mut();

        let status = aro_object_read(
            object.as_ptr(),
            qualifier.as_ptr(),
            options.as_ptr(),
            &mut result
        );

        // Should succeed but return null
        assert_eq!(status, 0);
        let result_str = unsafe { CStr::from_ptr(result).to_str().unwrap() };
        let value: Value = serde_json::from_str(result_str).unwrap();
        assert!(value.is_null());

        aro_plugin_free(result);
    }
}
```

### Integration Testing with ARO

Create test ARO files that exercise your system object:

```aro
(* test-redis.aro - Integration tests for Redis plugin *)

(Application-Start: Redis Tests) {
    Log "Running Redis plugin tests..." to the <console>.

    (* Test 1: Write and read string *)
    Write "test-value" to the <redis: "test:string">.
    Read the <value> from the <redis: "test:string">.
    Compare the <value> against "test-value".
    Log "Test 1 passed: string read/write" to the <console>.

    (* Test 2: Write and read object *)
    Create the <obj> with { name: "Alice", age: 30 }.
    Write <obj> to the <redis: "test:object">.
    Read the <retrieved> from the <redis: "test:object">.
    Extract the <name> from the <retrieved: name>.
    Compare the <name> against "Alice".
    Log "Test 2 passed: object read/write" to the <console>.

    (* Cleanup *)
    Write null to the <redis: "test:string">.
    Write null to the <redis: "test:object">.

    Log "All Redis tests passed!" to the <console>.
    Return an <OK: status> for the <tests>.
}
```

### Mocking for Offline Testing

For CI/CD environments without external services, provide mock implementations:

```rust
#[cfg(test)]
mod mock_tests {
    use std::collections::HashMap;
    use std::sync::Mutex;
    use once_cell::sync::Lazy;

    // In-memory mock store
    static MOCK_STORE: Lazy<Mutex<HashMap<String, String>>> =
        Lazy::new(|| Mutex::new(HashMap::new()));

    fn mock_read(key: &str) -> Option<String> {
        MOCK_STORE.lock().unwrap().get(key).cloned()
    }

    fn mock_write(key: &str, value: &str) {
        MOCK_STORE.lock().unwrap().insert(key.to_string(), value.to_string());
    }

    #[test]
    fn test_mock_operations() {
        mock_write("test:key", "test:value");
        assert_eq!(mock_read("test:key"), Some("test:value".to_string()));
        assert_eq!(mock_read("nonexistent"), None);
    }
}
```

## Summary

System object plugins extend ARO's I/O vocabulary. By implementing the read/write protocol, your plugin's data stores become first-class citizens in ARO code, accessible through the same natural syntax as built-in objects like `<file>` and `<console>`.

The key concepts from this chapter:

- **Source/Sink Model**: System objects are classified by their I/O direction
- **Qualifier Pattern**: Parameters embedded in the object reference
- **Capability Declarations**: Control which ARO actions can use the object
- **Connection Management**: Lazy initialization, pooling, graceful shutdown
- **Testing**: Unit tests for C interface, integration tests with ARO

System object plugins work best for:
- **Data stores**: Redis, Elasticsearch, PostgreSQL, MongoDB
- **Cloud services**: S3, GCS, Azure Blob Storage
- **Message queues**: Kafka, RabbitMQ, SQS
- **External APIs**: Weather services, payment gateways, notification systems

In the next chapter, we'll explore hybrid plugins that combine native code with ARO files—giving you the best of both worlds: native performance and ARO's declarative expressiveness.
