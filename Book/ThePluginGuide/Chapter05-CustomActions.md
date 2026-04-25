# Chapter 5: Providing Custom Actions

> *"A language that doesn't affect the way you think about programming is not worth knowing."*
> — Alan Perlis

In previous chapters, we explored how plugins provide services called via the `<Call>` action. But there's a more powerful integration: **custom actions**. Instead of:

```aro
Call the <hash> from the <crypto: sha256> with { input: <password> }.
```

Your plugin can provide a native action verb:

```aro
Hash the <hash> from the <password> with sha256.
```

Custom actions feel like built-in ARO features. They follow the same `Action the <result> preposition the <object>` syntax, support the same prepositions, and integrate seamlessly with ARO's execution model. This chapter shows you how to create them.

## 5.1 Actions vs Services

Understanding the distinction between actions and services clarifies when to use each.

### Services via `<Call>`

Services are invoked through the `<Call>` action with explicit service and method names:

```aro
(* Service invocation - explicit naming *)
Call the <result> from the <image: resize> with {
    file: <input-file>,
    width: 800,
    height: 600
}.
```

**Characteristics:**
- Explicit service/method naming
- Always uses `from` preposition
- Arguments passed as a map
- Good for multi-method APIs
- Clear that it's a plugin call

### Custom Actions

Custom actions provide new verbs that work like built-in actions:

```aro
(* Custom action - native feel *)
Resize the <thumbnail> from the <image> with { width: 200, height: 200 }.

(* Or with qualifier syntax *)
Resize the <thumbnail: 200x200> from the <image>.
```

**Characteristics:**
- Custom verb (`Resize`, `Hash`, `Encrypt`)
- Supports multiple prepositions (`from`, `to`, `with`, `for`)
- Natural ARO syntax
- Feels like a built-in feature
- Better for single-purpose operations

### When to Use Each

| Use Case | Recommendation |
|----------|----------------|
| Multi-method API (CRUD operations) | Service via `<Call>` |
| Single focused operation | Custom action |
| Complex argument structure | Service via `<Call>` |
| Natural language fit | Custom action |
| Multiple plugins with same operation | Service (namespaced) |
| Core data transformation | Custom action |

## 5.2 Action Anatomy

Before implementing custom actions, understand ARO's action model.

### The Action Protocol

Every ARO action has these properties:

```swift
protocol ActionImplementation {
    /// Semantic role: request, own, response, or export
    static var role: ActionRole { get }

    /// Verbs that trigger this action (e.g., ["hash", "digest"])
    static var verbs: Set<String> { get }

    /// Valid prepositions (e.g., [.from, .with])
    static var validPrepositions: Set<Preposition> { get }

    /// Execute the action
    func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable
}
```

### Action Roles

Actions are classified by their data flow direction:

| Role | Direction | Examples |
|------|-----------|----------|
| `request` | External → Internal | Extract, Retrieve, Fetch, Read |
| `own` | Internal → Internal | Compute, Transform, Validate, Hash |
| `response` | Internal → External | Return, Send, Log |
| `export` | Makes data available | Publish, Emit, Store |

### Prepositions

Prepositions connect the result and object:

| Preposition | Typical Use |
|-------------|-------------|
| `from` | Data source: `Extract the <id> from the <request>` |
| `to` | Destination: `Send the <message> to the <client>` |
| `with` | Parameters: `Create the <user> with { name: "Alice" }` |
| `for` | Purpose: `Return an <OK: status> for the <request>` |
| `into` | Container: `Store the <user> into the <repository>` |
| `as` | Type/format: `Parse the <data> as <JSON: format>` |
| `against` | Comparison: `Compare the <a> against the <b>` |
| `via` | Method: `Request the <data> via GET the <url>` |

### Result and Object Descriptors

When your action executes, it receives:

**ResultDescriptor:**
- `base`: The variable name to bind (e.g., "hash")
- `specifiers`: List of specifiers (e.g., `["sha256"]` in `<hash: sha256>`)

**ObjectDescriptor:**
- `base`: The source variable name (e.g., "password")
- `preposition`: How it's connected (e.g., `.from`)
- `specifiers`: Additional specifiers from the statement

### Plugin Input JSON Structure

When the runtime calls your plugin, it passes a richer JSON payload than earlier versions. The full structure is:

```json
{
  "result": {
    "base": "hash",
    "specifiers": ["sha256"]
  },
  "source": {
    "base": "password",
    "specifiers": []
  },
  "preposition": "from",
  "_context": {
    "requestId": "req-abc123",
    "featureSet": "createUser",
    "businessActivity": "User API"
  },
  "_with": {
    "algorithm": "sha512",
    "encoding": "hex"
  }
}
```

Key fields:

| Field | Description |
|-------|-------------|
| `result` | Full `ResultDescriptor`: `base` name and `specifiers` array |
| `source` | Full `ObjectDescriptor`: `base` name and `specifiers` array |
| `preposition` | The preposition used (`"from"`, `"to"`, `"with"`, `"for"`, etc.) |
| `_context` | Execution context: `requestId`, `featureSet`, `businessActivity` |
| `_with` | With-clause parameters as a **nested object** (not merged flat) |

Note: `_with` is always a nested object. If the ARO statement is `Hash the <result> from the <data> with { algorithm: "sha512" }`, your plugin receives `_with: { "algorithm": "sha512" }` — not `algorithm` at the top level.

### Action Response JSON Structure

Your action returns a JSON object. In addition to result data, you can include an `_events` key to emit domain events:

```json
{
  "hash": "a9f3...",
  "algorithm": "sha256",
  "_events": [
    {
      "type": "HashComputed",
      "data": { "algorithm": "sha256", "inputLength": 32 }
    }
  ]
}
```

The `_events` array is optional. Each entry has:
- `type`: The event name (string)
- `data`: Arbitrary event payload (object)

Events are dispatched to the ARO event bus after the action completes, triggering any matching `Handler` feature sets.

## 5.3 Declaring Custom Actions

Custom actions are declared in the `plugin.yaml` manifest with full metadata.

### Basic Declaration

```yaml
name: crypto-plugin
version: 1.0.0

provides:
  - type: rust-plugin
    path: src/
    actions:
      - name: Hash
        role: own
        verbs: [hash, digest]
        prepositions: [from, with]
        description: Compute cryptographic hash of data
```

### Extended Action Metadata

For complete integration, provide full action specifications:

```yaml
provides:
  - type: rust-plugin
    path: src/
    actions:
      - name: Hash
        role: own
        verbs: [hash, digest, checksum]
        prepositions: [from, with]
        description: Compute cryptographic hash of data
        arguments:
          algorithm:
            type: string
            default: sha256
            values: [sha256, sha512, md5, blake3]
          encoding:
            type: string
            default: hex
            values: [hex, base64, raw]

      - name: Encrypt
        role: own
        verbs: [encrypt, encipher]
        prepositions: [with, for]
        description: Encrypt data with a key
        arguments:
          algorithm:
            type: string
            default: aes-256-gcm

      - name: Decrypt
        role: own
        verbs: [decrypt, decipher]
        prepositions: [with, from]
        description: Decrypt data with a key
```

### The `aro_plugin_info` Response

Your plugin's info function returns action metadata. `aro_plugin_execute` is **optional** — qualifier-only or system-object-only plugins do not need to implement it:

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
      "verbs": ["encrypt", "encipher"],
      "prepositions": ["with", "for"]
    },
    {
      "name": "Decrypt",
      "role": "own",
      "verbs": ["decrypt", "decipher"],
      "prepositions": ["with", "from"]
    }
  ]
}
```

A plugin that only provides qualifiers (no custom action verbs) can return `"actions": []` and omit `aro_plugin_execute` entirely.

## 5.4 Implementing Custom Actions

Let's implement a crypto plugin with custom actions in Rust.

### Project Structure

```
plugin-crypto/
├── plugin.yaml
├── Cargo.toml
└── src/
    └── lib.rs
```

### The Manifest

```yaml
# plugin.yaml
name: plugin-crypto
version: 1.0.0
description: Cryptographic operations as native ARO actions

provides:
  - type: rust-plugin
    path: src/
    build:
      cargo-target: cdylib
    actions:
      - name: Hash
        role: own
        verbs: [hash, digest]
        prepositions: [from, with]

      - name: Encrypt
        role: own
        verbs: [encrypt]
        prepositions: [with]

      - name: Decrypt
        role: own
        verbs: [decrypt]
        prepositions: [with, from]
```

### The Implementation

```rust
// src/lib.rs

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use sha2::{Sha256, Sha512, Digest};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use aes_gcm::aead::{Aead, NewAead};
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use serde_json::{json, Value};

// ============================================================
// Plugin Information
// ============================================================

#[no_mangle]
pub extern "C" fn aro_plugin_info() -> *const c_char {
    let info = json!({
        "name": "plugin-crypto",
        "version": "1.0.0",
        "actions": [
            {
                "name": "Hash",
                "role": "own",
                "verbs": ["hash", "digest"],
                "prepositions": ["from", "with"],
                "description": "Compute cryptographic hash"
            },
            {
                "name": "Encrypt",
                "role": "own",
                "verbs": ["encrypt"],
                "prepositions": ["with"],
                "description": "Encrypt data with AES-256-GCM"
            },
            {
                "name": "Decrypt",
                "role": "own",
                "verbs": ["decrypt"],
                "prepositions": ["with", "from"],
                "description": "Decrypt AES-256-GCM encrypted data"
            }
        ]
    });

    CString::new(info.to_string()).unwrap().into_raw()
}

// ============================================================
// Action Execution
// ============================================================

/// Execute an action
/// Called by ARO runtime when the action verb is used.
/// This function is REQUIRED for action-providing plugins.
/// Qualifier-only plugins may omit it.
#[no_mangle]
pub extern "C" fn aro_plugin_execute(
    action_ptr: *const c_char,
    input_ptr: *const c_char,
    result_ptr: *mut *mut c_char
) -> i32 {
    let action = unsafe { CStr::from_ptr(action_ptr).to_str().unwrap_or("") };
    let input_json = unsafe { CStr::from_ptr(input_ptr).to_str().unwrap_or("{}") };

    // Input is the richer ARO-0073 structure:
    // {
    //   "result":      { "base": "hash", "specifiers": ["sha256"] },
    //   "source":      { "base": "password", "specifiers": [] },
    //   "preposition": "from",
    //   "_context":    { "requestId": "...", "featureSet": "...", "businessActivity": "..." },
    //   "_with":       { "algorithm": "sha512", "encoding": "hex" }
    // }
    let input: Value = serde_json::from_str(input_json).unwrap_or(json!({}));

    let result = match action.to_lowercase().as_str() {
        "hash" | "digest" => execute_hash(&input),
        "encrypt" => execute_encrypt(&input),
        "decrypt" => execute_decrypt(&input),
        _ => Err(format!("Unknown action: {}", action))
    };

    match result {
        Ok(value) => {
            unsafe { *result_ptr = CString::new(value.to_string()).unwrap().into_raw(); }
            0
        }
        Err(e) => {
            let error = json!({"error": e});
            unsafe { *result_ptr = CString::new(error.to_string()).unwrap().into_raw(); }
            1
        }
    }
}

// ============================================================
// Hash Action
// ============================================================

fn execute_hash(input: &Value) -> Result<Value, String> {
    // Get the data to hash from source.base (resolved by runtime)
    // The "source" field contains the full ObjectDescriptor
    let data = input.get("source")
        .and_then(|s| s.get("base"))
        .and_then(|v| v.as_str())
        .ok_or("Missing data to hash")?;

    // Get algorithm:
    //   1. From result specifier: Hash the <result: sha256> from <data>
    //   2. From _with parameters: Hash the <result> from <data> with { algorithm: "sha256" }
    let result_specifiers = input.get("result")
        .and_then(|r| r.get("specifiers"))
        .and_then(|s| s.as_array());

    let algorithm = result_specifiers
        .and_then(|specs| specs.first())
        .and_then(|v| v.as_str())
        .or_else(|| {
            input.get("_with")
                .and_then(|w| w.get("algorithm"))
                .and_then(|v| v.as_str())
        })
        .unwrap_or("sha256");

    // Get output encoding from _with (nested, not flat)
    let encoding = input.get("_with")
        .and_then(|w| w.get("encoding"))
        .and_then(|v| v.as_str())
        .unwrap_or("hex");

    // Compute hash
    let hash_bytes: Vec<u8> = match algorithm {
        "sha256" => {
            let mut hasher = Sha256::new();
            hasher.update(data.as_bytes());
            hasher.finalize().to_vec()
        }
        "sha512" => {
            let mut hasher = Sha512::new();
            hasher.update(data.as_bytes());
            hasher.finalize().to_vec()
        }
        _ => return Err(format!("Unsupported algorithm: {}", algorithm))
    };

    // Encode result
    let hash_string = match encoding {
        "hex" => hex::encode(&hash_bytes),
        "base64" => BASE64.encode(&hash_bytes),
        _ => return Err(format!("Unsupported encoding: {}", encoding))
    };

    Ok(json!({
        "hash": hash_string,
        "algorithm": algorithm,
        "encoding": encoding
    }))
}

// ============================================================
// Encrypt Action
// ============================================================

fn execute_encrypt(input: &Value) -> Result<Value, String> {
    // Data to encrypt comes from source.base
    let data = input.get("source")
        .and_then(|s| s.get("base"))
        .and_then(|v| v.as_str())
        .ok_or("Missing data to encrypt")?;

    // Key comes from _with parameters (never merged flat)
    let key_str = input.get("_with")
        .and_then(|w| w.get("key"))
        .and_then(|v| v.as_str())
        .ok_or("Missing encryption key")?;

    // Derive 32-byte key from input (in production, use proper key derivation)
    let mut key_bytes = [0u8; 32];
    let key_input = key_str.as_bytes();
    for (i, byte) in key_input.iter().enumerate().take(32) {
        key_bytes[i] = *byte;
    }

    let key = Key::from_slice(&key_bytes);
    let cipher = Aes256Gcm::new(key);

    // Generate random nonce
    let nonce_bytes: [u8; 12] = rand::random();
    let nonce = Nonce::from_slice(&nonce_bytes);

    // Encrypt
    let ciphertext = cipher.encrypt(nonce, data.as_bytes())
        .map_err(|e| format!("Encryption failed: {}", e))?;

    // Combine nonce + ciphertext and encode
    let mut combined = nonce_bytes.to_vec();
    combined.extend(ciphertext);
    let encrypted = BASE64.encode(&combined);

    Ok(json!({
        "encrypted": encrypted,
        "algorithm": "aes-256-gcm"
    }))
}

// ============================================================
// Decrypt Action
// ============================================================

fn execute_decrypt(input: &Value) -> Result<Value, String> {
    // Encrypted data comes from source.base
    let encrypted = input.get("source")
        .and_then(|s| s.get("base"))
        .and_then(|v| v.as_str())
        .ok_or("Missing data to decrypt")?;

    // Key comes from _with parameters (never merged flat)
    let key_str = input.get("_with")
        .and_then(|w| w.get("key"))
        .and_then(|v| v.as_str())
        .ok_or("Missing decryption key")?;

    // Derive key (same as encrypt)
    let mut key_bytes = [0u8; 32];
    let key_input = key_str.as_bytes();
    for (i, byte) in key_input.iter().enumerate().take(32) {
        key_bytes[i] = *byte;
    }

    let key = Key::from_slice(&key_bytes);
    let cipher = Aes256Gcm::new(key);

    // Decode and split nonce + ciphertext
    let combined = BASE64.decode(encrypted)
        .map_err(|e| format!("Invalid base64: {}", e))?;

    if combined.len() < 12 {
        return Err("Invalid encrypted data".to_string());
    }

    let nonce = Nonce::from_slice(&combined[..12]);
    let ciphertext = &combined[12..];

    // Decrypt
    let plaintext = cipher.decrypt(nonce, ciphertext)
        .map_err(|_| "Decryption failed - invalid key or corrupted data")?;

    let decrypted = String::from_utf8(plaintext)
        .map_err(|e| format!("Invalid UTF-8: {}", e))?;

    Ok(json!({
        "decrypted": decrypted
    }))
}

// ============================================================
// Memory Management
// ============================================================

#[no_mangle]
pub extern "C" fn aro_plugin_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { let _ = CString::from_raw(ptr); }
    }
}
```

### Using the Custom Actions

Now your actions work like native ARO verbs:

```aro
(Application-Start: Crypto Demo) {
    Create the <password> with "my-secret-password".
    Create the <encryption-key> with "32-byte-key-for-aes-encryption!".

    (* Hash with qualifier syntax *)
    Hash the <password-hash: sha256> from the <password>.
    Log "SHA-256: " ++ <password-hash: hash> to the <console>.

    (* Hash with argument syntax *)
    Hash the <sha512-hash> from the <password> with { algorithm: "sha512" }.
    Log "SHA-512: " ++ <sha512-hash: hash> to the <console>.

    (* Encrypt data *)
    Create the <secret-data> with "Sensitive information here".
    Encrypt the <encrypted> with <secret-data> using <encryption-key>.
    Log "Encrypted: " ++ <encrypted: encrypted> to the <console>.

    (* Decrypt data *)
    Decrypt the <decrypted> from the <encrypted: encrypted> with <encryption-key>.
    Log "Decrypted: " ++ <decrypted: decrypted> to the <console>.

    Return an <OK: status> for the <demo>.
}
```

## 5.5 Advanced Action Patterns

### Multiple Verbs, One Action

A single action can respond to multiple verbs:

```yaml
actions:
  - name: HashAction
    verbs: [hash, digest, checksum, fingerprint]
    # All these work:
    # Hash the <result> from <data>.
    # Digest the <result> from <data>.
    # <Checksum> the <result> from <data>.
    # <Fingerprint> the <result> from <data>.
```

### Qualifier-Based Dispatch

Use the result specifier to specify options:

```aro
(* Specifier on result picks algorithm *)
Hash the <result: sha256> from the <data>.
Hash the <result: sha512> from the <data>.
Hash the <result: md5> from the <data>.
```

Implementation reads from `result.specifiers[0]`:

```rust
fn execute_hash(input: &Value) -> Result<Value, String> {
    // Specifier is now in result.specifiers (not a flat "qualifier" key)
    let algorithm = input.get("result")
        .and_then(|r| r.get("specifiers"))
        .and_then(|s| s.as_array())
        .and_then(|arr| arr.first())
        .and_then(|v| v.as_str())
        .unwrap_or("sha256");

    // ... dispatch based on algorithm
}
```

### Preposition-Based Behavior

Different prepositions can trigger different behaviors:

```yaml
actions:
  - name: Transform
    verbs: [transform, convert]
    prepositions: [from, to, into, as]
```

```aro
(* Different prepositions, different meanings *)
Transform the <json> from the <xml>.        (* Convert XML to JSON *)
Transform the <data> to uppercase.          (* Apply transformation *)
Transform the <user> into the <dto>.        (* Map to different type *)
Transform the <text> as <Base64: encoding>. (* Encode as format *)
```

The `preposition` field is now always present as a top-level string in the input JSON:

```rust
fn execute_transform(input: &Value) -> Result<Value, String> {
    // Preposition is a top-level string field
    let preposition = input.get("preposition")
        .and_then(|v| v.as_str())
        .unwrap_or("from");

    match preposition {
        "from" => transform_from(input),
        "to" => transform_to(input),
        "into" => transform_into(input),
        "as" => transform_as(input),
        _ => Err(format!("Unsupported preposition: {}", preposition))
    }
}
```

### Contextual Actions

Actions can access the execution context for richer behavior via `_context`:

```rust
fn execute_action(input: &Value) -> Result<Value, String> {
    // _context carries request and feature set information
    let request_id = input.get("_context")
        .and_then(|ctx| ctx.get("requestId"))
        .and_then(|v| v.as_str());

    let feature_set = input.get("_context")
        .and_then(|ctx| ctx.get("featureSet"))
        .and_then(|v| v.as_str());

    let business_activity = input.get("_context")
        .and_then(|ctx| ctx.get("businessActivity"))
        .and_then(|v| v.as_str());

    // Access environment
    let api_key = std::env::var("API_KEY").ok();

    // Use context in execution
    // ...
}
```

### Emitting Domain Events

Actions can emit domain events by returning `_events` in the response JSON. The runtime dispatches these events to the ARO event bus after the action completes:

```rust
fn execute_hash(input: &Value) -> Result<Value, String> {
    // ... compute hash ...

    Ok(json!({
        "hash": hash_string,
        "algorithm": algorithm,
        "_events": [
            {
                "type": "HashComputed",
                "data": {
                    "algorithm": algorithm,
                    "encodingUsed": encoding
                }
            }
        ]
    }))
}
```

In ARO, a `HashComputed Handler` feature set would then be triggered automatically:

```aro
(Log Hash Audit: HashComputed Handler) {
    Extract the <algorithm> from the <event: algorithm>.
    Log "Hash computed using: " ++ <algorithm> to the <console>.
    Return an <OK: status> for the <audit>.
}
```

### Services via `aro_plugin_execute`

System objects and services provided by plugins are also dispatched through `aro_plugin_execute`, using a `service:<method>` action name convention. There is no separate `_call` function:

```rust
// Service calls arrive as "service:<method>"
pub extern "C" fn aro_plugin_execute(
    action_ptr: *const c_char,
    input_ptr: *const c_char,
    result_ptr: *mut *mut c_char
) -> i32 {
    let action = unsafe { CStr::from_ptr(action_ptr).to_str().unwrap_or("") };

    let result = if action.starts_with("service:") {
        let method = &action["service:".len()..];
        execute_service_method(method, &input)
    } else {
        match action {
            "hash" | "digest" => execute_hash(&input),
            _ => Err(format!("Unknown action: {}", action))
        }
    };
    // ...
}
```

### Subscribing to Events

Plugins can subscribe to domain events by exporting `aro_plugin_on_event`. The runtime calls this function whenever a matching event is emitted:

```rust
/// Called by the ARO runtime when a domain event is emitted.
/// Return 0 on success, non-zero on error.
#[no_mangle]
pub extern "C" fn aro_plugin_on_event(
    event_type_ptr: *const c_char,
    event_json_ptr: *const c_char,
    result_ptr: *mut *mut c_char
) -> i32 {
    let event_type = unsafe { CStr::from_ptr(event_type_ptr).to_str().unwrap_or("") };
    let event_json = unsafe { CStr::from_ptr(event_json_ptr).to_str().unwrap_or("{}") };

    let event: Value = serde_json::from_str(event_json).unwrap_or(json!({}));

    match event_type {
        "UserCreated" => handle_user_created(&event),
        "HashComputed" => handle_hash_computed(&event),
        _ => { /* ignore unknown events */ }
    }

    unsafe { *result_ptr = CString::new("{}").unwrap().into_raw(); }
    0
}
```

Declare the events your plugin subscribes to in `aro_plugin_info`:

```json
{
  "name": "audit-plugin",
  "version": "1.0.0",
  "subscribes": ["UserCreated", "HashComputed"]
}
```

## 5.6 Action Registration Flow

Understanding how actions are registered helps debug issues.

### Registration Sequence

```
1. Plugin Loaded
   └── UnifiedPluginLoader.loadPlugin()

2. Plugin Info Parsed
   └── aro_plugin_info() returns action metadata

3. Actions Registered
   └── NativePluginHost.registerActions()
       └── ActionRegistry.registerDynamic(verb, handler)

4. ARO Code Parsed
   └── Parser recognizes custom verb

5. Action Executed
   └── ExecutionEngine looks up verb
       └── ActionRegistry.dynamicHandler(verb)
           └── NativePluginActionWrapper.handle()
               └── aro_plugin_execute(action, input)
```

### Debugging Registration

Check if your action is registered:

```bash
# List all registered actions
aro actions list

# Output:
# Built-in actions:
#   extract, compute, return, ...
#
# Plugin actions:
#   hash (plugin-crypto)
#   encrypt (plugin-crypto)
#   decrypt (plugin-crypto)
```

### Common Issues

**Action not found:**
- Verify `aro_plugin_info()` returns correct JSON
- Check verb is lowercase in registration
- Ensure plugin loads without errors

**Wrong preposition error:**
- Verify preposition is in `validPrepositions` list
- Check manifest matches implementation

**Arguments not received:**
- Check input JSON parsing
- Verify argument names match ARO syntax

## 5.7 Testing Custom Actions

### Unit Testing

Test action execution directly:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hash_sha256() {
        // Use the ARO-0073 input structure: result/source descriptors + _with
        let input = json!({
            "result": { "base": "hash", "specifiers": ["sha256"] },
            "source": { "base": "hello world", "specifiers": [] },
            "preposition": "from",
            "_context": { "requestId": "test-1", "featureSet": "TestHash", "businessActivity": "Test" },
            "_with": {}
        });

        let result = execute_hash(&input).unwrap();

        assert!(result.get("hash").is_some());
        assert_eq!(result["algorithm"], "sha256");
    }

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let plaintext = "secret message";
        let key = "test-key-32-bytes-for-aes-256!!";

        // Encrypt — key comes from _with, not flat
        let encrypt_input = json!({
            "result": { "base": "encrypted", "specifiers": [] },
            "source": { "base": plaintext, "specifiers": [] },
            "preposition": "with",
            "_context": { "requestId": "test-2", "featureSet": "TestEncrypt", "businessActivity": "Test" },
            "_with": { "key": key }
        });
        let encrypted = execute_encrypt(&encrypt_input).unwrap();

        // Decrypt — key also comes from _with
        let decrypt_input = json!({
            "result": { "base": "decrypted", "specifiers": [] },
            "source": { "base": encrypted["encrypted"], "specifiers": [] },
            "preposition": "from",
            "_context": { "requestId": "test-3", "featureSet": "TestDecrypt", "businessActivity": "Test" },
            "_with": { "key": key }
        });
        let decrypted = execute_decrypt(&decrypt_input).unwrap();

        assert_eq!(decrypted["decrypted"], plaintext);
    }
}
```

### Integration Testing

Test with ARO code:

```aro
(* tests/crypto-actions.aro *)

(Application-Start: Crypto Action Tests) {
    Log "Testing crypto actions..." to the <console>.

    (* Test 1: Hash action *)
    Hash the <hash1: sha256> from "test".
    When <hash1: hash> is empty:
        Return a <ServerError: status> with "Hash failed".
    Log "PASS: Hash action" to the <console>.

    (* Test 2: Encrypt/Decrypt roundtrip *)
    Create the <key> with "test-encryption-key-32bytes!".
    Create the <secret> with "sensitive data".

    Encrypt the <encrypted> with <secret> using <key>.
    Decrypt the <decrypted> from <encrypted: encrypted> with <key>.

    When <decrypted: decrypted> is not <secret>:
        Return a <ServerError: status> with "Roundtrip failed".
    Log "PASS: Encrypt/Decrypt roundtrip" to the <console>.

    Log "All tests passed!" to the <console>.
    Return an <OK: status> for the <tests>.
}
```

## 5.8 Providing Custom Qualifiers

Beyond custom actions, plugins can provide **custom qualifiers**—transformations that apply to values using the specifier syntax `<variable: qualifier>`. While actions are verbs, qualifiers are transformations that can be applied anywhere a value is used.

### What Are Qualifiers?

Qualifiers transform values in place:

```aro
(* Built-in qualifiers *)
Log <user: name> to the <console>.           (* Property access *)
Compute the <len: length> from the <text>.   (* Length qualifier *)

(* Plugin-provided qualifiers *)
Compute the <item: pick-random> from the <list>.  (* Random selection *)
Log <numbers: reverse> to the <console>.          (* Reversed list *)
Compute the <total: sum> from the <values>.       (* Sum of numbers *)
```

### Declaring Qualifiers

Qualifiers are declared in `aro_plugin_info()` alongside actions. Use `accepts_parameters: true` for qualifiers that accept a `_with` clause:

```json
{
  "name": "plugin-collection",
  "version": "1.0.0",
  "actions": [],
  "qualifiers": [
    {
      "name": "pick-random",
      "inputTypes": ["List"],
      "description": "Picks a random element from a list"
    },
    {
      "name": "shuffle",
      "inputTypes": ["List", "String"],
      "description": "Shuffles elements or characters"
    },
    {
      "name": "reverse",
      "inputTypes": ["List", "String"],
      "description": "Reverses elements or characters"
    },
    {
      "name": "sum",
      "inputTypes": ["List"],
      "description": "Sums numeric list elements"
    },
    {
      "name": "take",
      "inputTypes": ["List"],
      "accepts_parameters": true,
      "description": "Takes the first N elements from a list"
    }
  ]
}
```

**Input Types:**
- `String` - String values
- `Int` - Integer values
- `Double` - Floating-point values
- `Bool` - Boolean values
- `List` - Arrays/lists
- `Object` - Dictionaries/objects

**`accepts_parameters`:** When `true`, the qualifier receives a `_with` object in the input JSON containing any parameters passed in the ARO `with` clause.

### Implementing the Qualifier Function

Plugins provide an `aro_plugin_qualifier` function for executing qualifier transformations:

**C ABI Interface:**
```c
// Execute qualifier transformation
// Returns JSON: {"result": <value>} or {"error": "message"}
char* aro_plugin_qualifier(const char* qualifier, const char* input_json);
```

**Input JSON Format:**
```json
{
  "value": [1, 2, 3, 4, 5],
  "type": "List",
  "_with": {
    "n": 3
  }
}
```

The `_with` field is always present (as an empty object `{}` when no parameters are provided). For qualifiers with `accepts_parameters: true`, the caller passes parameters via a `with` clause in ARO code:

```aro
(* Qualifier with parameters *)
Compute the <first-three: Collections.take> from the <numbers> with { n: 3 }.
```

**Output JSON Format:**
```json
{"result": [1, 2, 3]}  // Success: transformed value
{"error": "message"}    // Failure: error message
```

### Qualifier Chaining

Qualifiers can be chained using pipe syntax. The output of each qualifier feeds into the next, evaluated left to right:

```aro
(* Chain sort then take-3 *)
Compute the <top-three: Collections.sort | Collections.take> from the <scores> with { n: 3 }.

(* Chain reverse then pick-random *)
Compute the <choice: Collections.reverse | Collections.pick-random> from the <items>.
```

Each qualifier in the chain receives the result of the previous one as its `value`. The `_with` parameters are passed to all qualifiers in the chain.

### Qualifier Conflict Detection

If two loaded plugins register a qualifier under the same `namespace.qualifier` identifier, the runtime raises a load-time error:

```
Error: Qualifier conflict — both 'plugin-stats' and 'plugin-math' register 'stats.sort'.
       Use plugin handle aliasing in plugin.yaml to resolve.
```

To resolve conflicts, alias one plugin's handle in your application's `plugin.yaml`:

```yaml
dependencies:
  - name: plugin-stats
    handle: Stats        # canonical handle
  - name: plugin-math
    handle: Math         # renamed to avoid collision with Stats.sort
```

With aliasing, `Stats.sort` and `Math.sort` can coexist without conflict.

### Example: Swift Implementation

```swift
@_cdecl("aro_plugin_qualifier")
public func aroPluginQualifier(
    qualifier: UnsafePointer<CChar>?,
    inputJson: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let qualifier = qualifier.map({ String(cString: $0) }),
          let inputJson = inputJson.map({ String(cString: $0) }) else {
        return strdup("{\"error\":\"Invalid input\"}")
    }

    guard let jsonData = inputJson.data(using: .utf8),
          let input = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
        return strdup("{\"error\":\"Invalid JSON\"}")
    }

    let value = input["value"]
    // _with is always present; use it for parameterised qualifiers
    let withParams = input["_with"] as? [String: Any] ?? [:]
    let result: [String: Any]

    switch qualifier {
    case "pick-random":
        guard let array = value as? [Any], !array.isEmpty else {
            return strdup("{\"error\":\"pick-random requires a non-empty list\"}")
        }
        let randomIndex = Int.random(in: 0..<array.count)
        result = ["result": array[randomIndex]]

    case "reverse":
        if let array = value as? [Any] {
            result = ["result": Array(array.reversed())]
        } else if let string = value as? String {
            result = ["result": String(string.reversed())]
        } else {
            return strdup("{\"error\":\"reverse requires List or String\"}")
        }

    case "take":
        // Parameterised qualifier: requires accepts_parameters: true in aro_plugin_info
        guard let array = value as? [Any] else {
            return strdup("{\"error\":\"take requires a list\"}")
        }
        let n = withParams["n"] as? Int ?? 1
        result = ["result": Array(array.prefix(n))]

    default:
        return strdup("{\"error\":\"Unknown qualifier: \(qualifier)\"}")
    }

    guard let resultData = try? JSONSerialization.data(withJSONObject: result),
          let resultString = String(data: resultData, encoding: .utf8) else {
        return strdup("{\"error\":\"Failed to serialize result\"}")
    }

    return strdup(resultString)
}
```

### Example: C Implementation

```c
char* aro_plugin_qualifier(const char* qualifier, const char* input_json) {
    char* result = malloc(4096);

    // Parse input JSON to get value and type
    // ... JSON parsing logic ...

    if (strcmp(qualifier, "first") == 0) {
        // Extract first element from array
        // Return: {"result": <first_element>}
    }
    else if (strcmp(qualifier, "size") == 0) {
        // Return count of array or string length
        // Return: {"result": <count>}
    }
    else {
        snprintf(result, 4096, "{\"error\":\"Unknown qualifier: %s\"}", qualifier);
    }

    return result;
}
```

### Example: Python Implementation

```python
def aro_plugin_qualifier(qualifier: str, input_json: str) -> str:
    import json
    params = json.loads(input_json)
    value = params.get("value")
    value_type = params.get("type", "Unknown")
    # _with is always present; access parameters from it (never flat)
    with_params = params.get("_with", {})

    if qualifier == "sort":
        if not isinstance(value, list):
            return json.dumps({"error": "sort requires a list"})
        return json.dumps({"result": sorted(value)})

    elif qualifier == "unique":
        if not isinstance(value, list):
            return json.dumps({"error": "unique requires a list"})
        seen = set()
        unique = []
        for item in value:
            key = tuple(item) if isinstance(item, list) else item
            if key not in seen:
                seen.add(key)
                unique.append(item)
        return json.dumps({"result": unique})

    elif qualifier == "sum":
        if not isinstance(value, list):
            return json.dumps({"error": "sum requires a list"})
        return json.dumps({"result": sum(v for v in value if isinstance(v, (int, float)))})

    elif qualifier == "take":
        # Parameterised qualifier — accepts_parameters: true in aro_plugin_info
        if not isinstance(value, list):
            return json.dumps({"error": "take requires a list"})
        n = with_params.get("n", 1)
        return json.dumps({"result": value[:n]})

    else:
        return json.dumps({"error": f"Unknown qualifier: {qualifier}"})
```

### Using Plugin Qualifiers

Once registered, qualifiers work in two contexts:

**1. In Compute Action (Result Specifier):**
```aro
Compute the <random-item: pick-random> from the <list>.
Compute the <sorted-list: sort> from the <numbers>.
Compute the <total: sum> from the <values>.
```

**2. In Expressions (Variable Specifier):**
```aro
Log <list: reverse> to the <console>.
When <numbers: min> < 0:
    Log "Has negative numbers" to the <console>.
```

### Qualifier vs Action: When to Use Each

| Use Case | Recommendation |
|----------|----------------|
| Transform a value inline | Qualifier |
| Operation with side effects | Action |
| Multiple input parameters | Action |
| Single value transformation | Qualifier |
| Returns same type | Qualifier |
| Returns different structure | Action |

### Type Safety

The runtime validates input types before calling your qualifier:

```json
{
  "name": "sum",
  "inputTypes": ["List"]  // Only accepts List
}
```

If called with wrong type:
```
Error: Qualifier 'sum' expects [List] but received String
```

### Complete Example: Collection Plugin

**plugin.yaml:**
```yaml
name: plugin-collection
version: 1.0.0
description: Collection qualifiers for ARO

provides:
  - type: swift-plugin
    path: Sources/
```

**Sources/CollectionPlugin.swift:**
```swift
@_cdecl("aro_plugin_info")
public func aroPluginInfo() -> UnsafeMutablePointer<CChar>? {
    let info: NSDictionary = [
        "name": "plugin-collection",
        "version": "1.0.0",
        "actions": [] as NSArray,
        "qualifiers": [
            ["name": "pick-random", "inputTypes": ["List"]],
            ["name": "shuffle", "inputTypes": ["List", "String"]],
            ["name": "reverse", "inputTypes": ["List", "String"]]
        ] as NSArray
    ]
    // ... serialize and return
}

@_cdecl("aro_plugin_qualifier")
public func aroPluginQualifier(
    qualifier: UnsafePointer<CChar>?,
    inputJson: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    // ... implementation
}
```

**main.aro:**
```aro
(Application-Start: Collection Demo) {
    Create the <numbers> with [1, 2, 3, 4, 5].

    (* Pick a random element *)
    Compute the <lucky: pick-random> from the <numbers>.
    Log "Lucky number: " ++ <lucky> to the <console>.

    (* Shuffle the list *)
    Compute the <shuffled: shuffle> from the <numbers>.
    Log "Shuffled: " ++ <shuffled> to the <console>.

    (* Reverse inline in expression *)
    Log "Reversed: " ++ <numbers: reverse> to the <console>.

    Return an <OK: status> for the <demo>.
}
```

## Summary

Custom actions are the most powerful form of ARO extension. They let you add new verbs that feel native to the language:

- **Declare actions** in `plugin.yaml` with role, verbs, and prepositions
- **Return metadata** from `aro_plugin_info()` with full action specifications
- **Implement execution** in `aro_plugin_execute()` handling all registered verbs — this function is **optional** for qualifier-only or system-object-only plugins
- **Use natural syntax** like `Hash the <result> from the <data>`

**ARO-0073 input JSON** passes richer data to every plugin call:
- `result` and `source` are full descriptor objects (`base` + `specifiers`), not flat strings
- `preposition` is an explicit top-level field
- `_context` carries `requestId`, `featureSet`, and `businessActivity`
- `_with` is always a **nested object** — parameters are never merged flat into the top level

**Qualifier enhancements:**
- Qualifiers that accept parameters declare `accepts_parameters: true`; the `_with` object is passed in the qualifier input
- Qualifiers can be chained with pipe syntax: `<result: stats.sort | list.take>`
- Namespace conflicts (two plugins registering the same `namespace.qualifier`) are detected at load time and must be resolved with handle aliasing

**Event integration:**
- Actions can return `_events: [{type, data}]` to emit domain events after execution
- Plugins can subscribe to events via `aro_plugin_on_event` and declare `subscribes` in `aro_plugin_info`
- Service methods route through `aro_plugin_execute("service:<method>", ...)` — no separate call function

Custom actions work best for:
- Core data transformations (hash, encrypt, compress)
- Domain-specific operations (validate, transform, normalize)
- Natural language fits (parse, render, analyze)

In the next chapter, we'll explore Swift plugins in depth, seeing how to leverage Swift's Foundation types and ecosystem for plugin development.
