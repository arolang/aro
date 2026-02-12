# Chapter 5: Providing Custom Actions

> *"A language that doesn't affect the way you think about programming is not worth knowing."*
> — Alan Perlis

In previous chapters, we explored how plugins provide services called via the `<Call>` action. But there's a more powerful integration: **custom actions**. Instead of:

```aro
<Call> the <hash> from the <crypto: sha256> with { input: <password> }.
```

Your plugin can provide a native action verb:

```aro
<Hash> the <hash> from the <password> with sha256.
```

Custom actions feel like built-in ARO features. They follow the same `<Action> the <result> preposition the <object>` syntax, support the same prepositions, and integrate seamlessly with ARO's execution model. This chapter shows you how to create them.

## 5.1 Actions vs Services

Understanding the distinction between actions and services clarifies when to use each.

### Services via `<Call>`

Services are invoked through the `<Call>` action with explicit service and method names:

```aro
(* Service invocation - explicit naming *)
<Call> the <result> from the <image: resize> with {
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
<Resize> the <thumbnail> from the <image> with { width: 200, height: 200 }.

(* Or with qualifier syntax *)
<Resize> the <thumbnail: 200x200> from the <image>.
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
| `from` | Data source: `<Extract> the <id> from the <request>` |
| `to` | Destination: `<Send> the <message> to the <client>` |
| `with` | Parameters: `<Create> the <user> with { name: "Alice" }` |
| `for` | Purpose: `<Return> an <OK: status> for the <request>` |
| `into` | Container: `<Store> the <user> into the <repository>` |
| `as` | Type/format: `<Parse> the <data> as <JSON: format>` |
| `against` | Comparison: `<Compare> the <a> against the <b>` |
| `via` | Method: `<Request> the <data> via GET the <url>` |

### Result and Object Descriptors

When your action executes, it receives:

**ResultDescriptor:**
- `base`: The variable name to bind (e.g., "hash")
- `qualifiers`: Optional qualifiers (e.g., "sha256" in `<hash: sha256>`)

**ObjectDescriptor:**
- `base`: The source variable name (e.g., "password")
- `preposition`: How it's connected (e.g., `.from`)
- `specifiers`: Additional specifiers from the statement

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

Your plugin's info function returns action metadata:

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
/// Called by ARO runtime when the action verb is used
#[no_mangle]
pub extern "C" fn aro_plugin_execute(
    action_ptr: *const c_char,
    input_ptr: *const c_char,
    result_ptr: *mut *mut c_char
) -> i32 {
    let action = unsafe { CStr::from_ptr(action_ptr).to_str().unwrap_or("") };
    let input_json = unsafe { CStr::from_ptr(input_ptr).to_str().unwrap_or("{}") };

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
    // Get the data to hash
    // Can come from "object" (the <object> in ARO syntax)
    // or "data" argument
    let data = input.get("object")
        .or_else(|| input.get("data"))
        .and_then(|v| v.as_str())
        .ok_or("Missing data to hash")?;

    // Get algorithm from qualifier or argument
    // Supports: <Hash> the <result: sha256> from <data>
    // Or: <Hash> the <result> from <data> with { algorithm: "sha256" }
    let algorithm = input.get("qualifier")
        .or_else(|| input.get("algorithm"))
        .and_then(|v| v.as_str())
        .unwrap_or("sha256");

    // Get output encoding
    let encoding = input.get("encoding")
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
    let data = input.get("object")
        .or_else(|| input.get("data"))
        .and_then(|v| v.as_str())
        .ok_or("Missing data to encrypt")?;

    let key_str = input.get("key")
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
    let encrypted = input.get("object")
        .or_else(|| input.get("data"))
        .and_then(|v| v.as_str())
        .ok_or("Missing data to decrypt")?;

    let key_str = input.get("key")
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
    <Create> the <password> with "my-secret-password".
    <Create> the <encryption-key> with "32-byte-key-for-aes-encryption!".

    (* Hash with qualifier syntax *)
    <Hash> the <password-hash: sha256> from the <password>.
    <Log> "SHA-256: " ++ <password-hash: hash> to the <console>.

    (* Hash with argument syntax *)
    <Hash> the <sha512-hash> from the <password> with { algorithm: "sha512" }.
    <Log> "SHA-512: " ++ <sha512-hash: hash> to the <console>.

    (* Encrypt data *)
    <Create> the <secret-data> with "Sensitive information here".
    <Encrypt> the <encrypted> with <secret-data> using <encryption-key>.
    <Log> "Encrypted: " ++ <encrypted: encrypted> to the <console>.

    (* Decrypt data *)
    <Decrypt> the <decrypted> from the <encrypted: encrypted> with <encryption-key>.
    <Log> "Decrypted: " ++ <decrypted: decrypted> to the <console>.

    <Return> an <OK: status> for the <demo>.
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
    # <Hash> the <result> from <data>.
    # <Digest> the <result> from <data>.
    # <Checksum> the <result> from <data>.
    # <Fingerprint> the <result> from <data>.
```

### Qualifier-Based Dispatch

Use the result qualifier to specify options:

```aro
(* Qualifier specifies algorithm *)
<Hash> the <result: sha256> from the <data>.
<Hash> the <result: sha512> from the <data>.
<Hash> the <result: md5> from the <data>.
```

Implementation:

```rust
fn execute_hash(input: &Value) -> Result<Value, String> {
    // Qualifier comes through as "qualifier" field
    let algorithm = input.get("qualifier")
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
<Transform> the <json> from the <xml>.        (* Convert XML to JSON *)
<Transform> the <data> to uppercase.          (* Apply transformation *)
<Transform> the <user> into the <dto>.        (* Map to different type *)
<Transform> the <text> as <Base64: encoding>. (* Encode as format *)
```

Implementation:

```rust
fn execute_transform(input: &Value) -> Result<Value, String> {
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

Actions can access the execution context for richer behavior:

```rust
fn execute_action(input: &Value) -> Result<Value, String> {
    // Access context variables
    let request_id = input.get("_context")
        .and_then(|ctx| ctx.get("requestId"))
        .and_then(|v| v.as_str());

    // Access environment
    let api_key = std::env::var("API_KEY").ok();

    // Use context in execution
    // ...
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
        let input = json!({
            "object": "hello world",
            "qualifier": "sha256"
        });

        let result = execute_hash(&input).unwrap();

        assert!(result.get("hash").is_some());
        assert_eq!(result["algorithm"], "sha256");
    }

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let plaintext = "secret message";
        let key = "test-key-32-bytes-for-aes-256!!";

        // Encrypt
        let encrypt_input = json!({
            "object": plaintext,
            "key": key
        });
        let encrypted = execute_encrypt(&encrypt_input).unwrap();

        // Decrypt
        let decrypt_input = json!({
            "object": encrypted["encrypted"],
            "key": key
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
    <Log> "Testing crypto actions..." to the <console>.

    (* Test 1: Hash action *)
    <Hash> the <hash1: sha256> from "test".
    <When> <hash1: hash> is empty:
        <Return> a <ServerError: status> with "Hash failed".
    <Log> "PASS: Hash action" to the <console>.

    (* Test 2: Encrypt/Decrypt roundtrip *)
    <Create> the <key> with "test-encryption-key-32bytes!".
    <Create> the <secret> with "sensitive data".

    <Encrypt> the <encrypted> with <secret> using <key>.
    <Decrypt> the <decrypted> from <encrypted: encrypted> with <key>.

    <When> <decrypted: decrypted> is not <secret>:
        <Return> a <ServerError: status> with "Roundtrip failed".
    <Log> "PASS: Encrypt/Decrypt roundtrip" to the <console>.

    <Log> "All tests passed!" to the <console>.
    <Return> an <OK: status> for the <tests>.
}
```

## Summary

Custom actions are the most powerful form of ARO extension. They let you add new verbs that feel native to the language:

- **Declare actions** in `plugin.yaml` with role, verbs, and prepositions
- **Return metadata** from `aro_plugin_info()` with full action specifications
- **Implement execution** in `aro_plugin_execute()` handling all registered verbs
- **Use natural syntax** like `<Hash> the <result> from the <data>`

Custom actions work best for:
- Core data transformations (hash, encrypt, compress)
- Domain-specific operations (validate, transform, normalize)
- Natural language fits (parse, render, analyze)

In the next chapter, we'll explore Swift plugins in depth, seeing how to leverage Swift's Foundation types and ecosystem for plugin development.
