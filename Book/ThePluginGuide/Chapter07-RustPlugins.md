# Chapter 7: Rust Plugins

*"Rust: where performance and safety finally stopped fighting."*

---

When performance matters—when every microsecond counts, when memory safety is non-negotiable, when you're processing gigabytes of data—Rust is the answer. This chapter shows you how to write Rust plugins that bring systems-programming power to your ARO applications.

## 7.1 Why Rust?

Rust offers a compelling combination of features for plugin development:

**Performance**: Rust compiles to native code with no runtime overhead. Your plugin runs as fast as handwritten C, often faster due to better optimization opportunities.

**Memory Safety**: Rust's ownership system eliminates entire categories of bugs—no null pointers, no buffer overflows, no data races. This matters especially for plugins that process untrusted input.

**Rich Ecosystem**: Cargo makes adding dependencies trivial. Need CSV parsing? `csv = "1.3"`. JSON handling? `serde_json = "1.0"`. Image processing? `image = "0.24"`.

**Predictable Resource Usage**: No garbage collector means no GC pauses. Memory usage is deterministic and controllable.

## 7.2 Project Structure

A Rust plugin follows standard Cargo conventions:

```
Plugins/
└── plugin-rust-csv/
    ├── plugin.yaml
    ├── Cargo.toml
    └── src/
        └── lib.rs
```

### Cargo.toml

The `Cargo.toml` must specify `cdylib` as the crate type:

```toml
[package]
name = "csv_plugin"
version = "1.0.0"
edition = "2021"
description = "ARO plugin for CSV parsing and formatting"
license = "MIT"

[lib]
name = "csv_plugin"
crate-type = ["cdylib"]    # Critical: builds a C-compatible dynamic library

[dependencies]
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
csv = "1.3"

[profile.release]
lto = true                 # Link-time optimization
opt-level = "z"            # Optimize for size (or "3" for speed)
```

Key configuration:

- **`crate-type = ["cdylib"]`**: Builds a C-compatible dynamic library (`.dylib`/`.so`/`.dll`)
- **`lto = true`**: Enables link-time optimization for smaller, faster binaries
- **`opt-level`**: `"z"` for size, `"3"` for maximum speed

### plugin.yaml

```yaml
name: plugin-rust-csv
version: 1.0.0
description: "A Rust plugin for CSV parsing and formatting"
author: "ARO Team"
license: MIT
aro-version: ">=0.1.0"

provides:
  - type: rust-plugin
    path: src/
    build:
      cargo-target: release
      output: target/release/libcsv_plugin.dylib
```

## 7.3 The FFI Interface

Rust plugins communicate with ARO through a C-compatible FFI (Foreign Function Interface). Three attributes make this work:

### `#[no_mangle]`

Prevents Rust from "mangling" the function name:

```rust
// Without #[no_mangle]: function might be named _ZN10csv_plugin15aro_plugin_info17h8c...
// With #[no_mangle]: function is named exactly "aro_plugin_info"
#[no_mangle]
pub extern "C" fn aro_plugin_info() -> *mut c_char {
    // ...
}
```

### `extern "C"`

Uses C calling conventions instead of Rust's:

```rust
pub extern "C" fn my_function(arg: *const c_char) -> i32 {
    // Uses C calling conventions
}
```

### C Types

Rust's FFI types from `std::ffi`:

| Rust FFI Type | C Equivalent | Usage |
|---------------|--------------|-------|
| `*const c_char` | `const char*` | Input strings |
| `*mut c_char` | `char*` | Output strings |
| `i32` | `int32_t` | Return codes |
| `CStr` | - | Safely wrap `*const c_char` |
| `CString` | - | Create owned C strings |

## 7.4 Your First Rust Plugin: Custom Actions

Let's build a data validation plugin—checking email formats, URLs, credit card numbers, and more.

### Step 1: Create the Project

```bash
mkdir -p Plugins/plugin-rust-validator/src
cd Plugins/plugin-rust-validator
```

### Step 2: Write Cargo.toml

```toml
[package]
name = "validator_plugin"
version = "1.0.0"
edition = "2021"

[lib]
name = "validator_plugin"
crate-type = ["cdylib"]

[dependencies]
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
regex = "1.10"
once_cell = "1.19"

[profile.release]
lto = true
opt-level = 3
```

### Step 3: Implement the Plugin

```rust
// src/lib.rs

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use once_cell::sync::Lazy;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

// MARK: - Plugin Metadata

/// Returns plugin metadata as a JSON string with custom action definitions.
///
/// Called once when the plugin is loaded.
/// The caller is responsible for freeing the returned string.
#[no_mangle]
pub extern "C" fn aro_plugin_info() -> *mut c_char {
    // Define custom actions with verbs and prepositions
    // This enables native ARO syntax: <ValidateEmail>, <ValidatePhone>, etc.
    let info = json!({
        "name": "plugin-rust-validator",
        "version": "1.0.0",
        "actions": [
            {
                "name": "ValidateEmail",
                "role": "own",
                "verbs": ["validateemail", "checkemail"],
                "prepositions": ["from", "with"]
            },
            {
                "name": "ValidateURL",
                "role": "own",
                "verbs": ["validateurl", "checkurl"],
                "prepositions": ["from", "with"]
            },
            {
                "name": "ValidatePhone",
                "role": "own",
                "verbs": ["validatephone", "checkphone"],
                "prepositions": ["from", "with"]
            },
            {
                "name": "ValidateCreditCard",
                "role": "own",
                "verbs": ["validatecreditcard", "checkcard"],
                "prepositions": ["from", "with"]
            },
            {
                "name": "ValidateUUID",
                "role": "own",
                "verbs": ["validateuuid", "checkuuid"],
                "prepositions": ["from"]
            }
        ]
    });

    CString::new(info.to_string()).unwrap().into_raw()
}

// MARK: - Main Entry Point

/// Execute a plugin action
///
/// # Arguments
/// * `action` - The action name (e.g., "validate-email")
/// * `input_json` - JSON string with input parameters
///
/// # Returns
/// JSON string with the result. Caller must free using `aro_plugin_free`.
#[no_mangle]
pub extern "C" fn aro_plugin_execute(
    action: *const c_char,
    input_json: *const c_char,
) -> *mut c_char {
    // Parse action name
    let action = match parse_cstr(action) {
        Ok(s) => s,
        Err(e) => return error_result(&e),
    };

    // Parse input JSON
    let input = match parse_cstr(input_json) {
        Ok(s) => s,
        Err(e) => return error_result(&e),
    };

    let input_value: Value = match serde_json::from_str(&input) {
        Ok(v) => v,
        Err(e) => return error_result(&format!("Invalid JSON: {}", e)),
    };

    // Dispatch to appropriate action
    let result = match action.as_str() {
        "validate-email" => validate_email(&input_value),
        "validate-url" => validate_url(&input_value),
        "validate-phone" => validate_phone(&input_value),
        "validate-credit-card" => validate_credit_card(&input_value),
        "validate-uuid" => validate_uuid(&input_value),
        _ => Err(format!("Unknown action: {}", action)),
    };

    // Return result
    match result {
        Ok(value) => CString::new(value.to_string()).unwrap().into_raw(),
        Err(e) => error_result(&e),
    }
}

/// Free memory allocated by the plugin
///
/// Must be called for every string returned by `aro_plugin_execute`.
#[no_mangle]
pub extern "C" fn aro_plugin_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            // Reconstruct the CString and drop it
            let _ = CString::from_raw(ptr);
        }
    }
}

// MARK: - Validation Actions

/// Compiled regex patterns (created once, reused for each call)
static EMAIL_REGEX: LazyRegex = Lazy::new(|| {
    Regex::new(r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$").unwrap()
});

static URL_REGEX: LazyRegex = Lazy::new(|| {
    Regex::new(r"^https?://[^\s/$.?#].[^\s]*$").unwrap()
});

static PHONE_REGEX: LazyRegex = Lazy::new(|| {
    Regex::new(r"^\+?[1-9]\d{1,14}$").unwrap()
});

static UUID_REGEX: LazyRegex = Lazy::new(|| {
    Regex::new(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$").unwrap()
});

/// Validate an email address
fn validate_email(input: &Value) -> Result<Value, String> {
    let email = get_string_field(input, "value")?;

    let is_valid = EMAIL_REGEX.is_match(&email);

    Ok(json!({
        "valid": is_valid,
        "value": email,
        "type": "email"
    }))
}

/// Validate a URL
fn validate_url(input: &Value) -> Result<Value, String> {
    let url = get_string_field(input, "value")?;

    let is_valid = URL_REGEX.is_match(&url);

    Ok(json!({
        "valid": is_valid,
        "value": url,
        "type": "url"
    }))
}

/// Validate a phone number (E.164 format)
fn validate_phone(input: &Value) -> Result<Value, String> {
    let phone = get_string_field(input, "value")?;

    // Remove common formatting characters
    let normalized: String = phone.chars()
        .filter(|c| c.is_ascii_digit() || *c == '+')
        .collect();

    let is_valid = PHONE_REGEX.is_match(&normalized);

    Ok(json!({
        "valid": is_valid,
        "value": phone,
        "normalized": normalized,
        "type": "phone"
    }))
}

/// Validate a credit card number using the Luhn algorithm
fn validate_credit_card(input: &Value) -> Result<Value, String> {
    let card = get_string_field(input, "value")?;

    // Remove spaces and dashes
    let digits: String = card.chars().filter(|c| c.is_ascii_digit()).collect();

    // Must be 13-19 digits
    if digits.len() < 13 || digits.len() > 19 {
        return Ok(json!({
            "valid": false,
            "value": card,
            "type": "credit-card",
            "error": "Invalid length"
        }));
    }

    // Luhn algorithm
    let is_valid = luhn_check(&digits);

    // Detect card type
    let card_type = detect_card_type(&digits);

    Ok(json!({
        "valid": is_valid,
        "value": card,
        "type": "credit-card",
        "card_type": card_type,
        "masked": mask_card_number(&digits)
    }))
}

/// Validate a UUID
fn validate_uuid(input: &Value) -> Result<Value, String> {
    let uuid = get_string_field(input, "value")?;

    let is_valid = UUID_REGEX.is_match(&uuid);

    // Extract version if valid
    let version = if is_valid {
        uuid.chars().nth(14).map(|c| c.to_string())
    } else {
        None
    };

    Ok(json!({
        "valid": is_valid,
        "value": uuid,
        "type": "uuid",
        "version": version
    }))
}

// MARK: - Helper Functions

/// Parse a C string into a Rust String
fn parse_cstr(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("Null pointer".to_string());
    }

    unsafe {
        CStr::from_ptr(ptr)
            .to_str()
            .map(|s| s.to_string())
            .map_err(|_| "Invalid UTF-8".to_string())
    }
}

/// Extract a string field from JSON
fn get_string_field(value: &Value, field: &str) -> Result<String, String> {
    value
        .get(field)
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| format!("Missing field: {}", field))
}

/// Create an error result JSON
fn error_result(message: &str) -> *mut c_char {
    let error = json!({ "error": message });
    CString::new(error.to_string()).unwrap().into_raw()
}

/// Luhn algorithm for credit card validation
fn luhn_check(digits: &str) -> bool {
    let mut sum = 0;
    let mut double = false;

    for c in digits.chars().rev() {
        if let Some(digit) = c.to_digit(10) {
            let mut d = digit;
            if double {
                d *= 2;
                if d > 9 {
                    d -= 9;
                }
            }
            sum += d;
            double = !double;
        }
    }

    sum % 10 == 0
}

/// Detect credit card type from number prefix
fn detect_card_type(digits: &str) -> &'static str {
    if digits.starts_with('4') {
        "Visa"
    } else if digits.starts_with("51") || digits.starts_with("52") ||
              digits.starts_with("53") || digits.starts_with("54") ||
              digits.starts_with("55") {
        "Mastercard"
    } else if digits.starts_with("34") || digits.starts_with("37") {
        "American Express"
    } else if digits.starts_with("6011") || digits.starts_with("65") {
        "Discover"
    } else {
        "Unknown"
    }
}

/// Mask a credit card number for display
fn mask_card_number(digits: &str) -> String {
    let len = digits.len();
    if len <= 4 {
        digits.to_string()
    } else {
        format!("****-****-****-{}", &digits[len-4..])
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_email_validation() {
        let input = json!({"value": "user@example.com"});
        let result = validate_email(&input).unwrap();
        assert_eq!(result["valid"], true);

        let input = json!({"value": "invalid-email"});
        let result = validate_email(&input).unwrap();
        assert_eq!(result["valid"], false);
    }

    #[test]
    fn test_credit_card_validation() {
        // Valid Visa test number
        let input = json!({"value": "4111111111111111"});
        let result = validate_credit_card(&input).unwrap();
        assert_eq!(result["valid"], true);
        assert_eq!(result["card_type"], "Visa");
    }

    #[test]
    fn test_luhn_algorithm() {
        assert!(luhn_check("4111111111111111")); // Valid Visa
        assert!(luhn_check("5500000000000004")); // Valid Mastercard
        assert!(!luhn_check("1234567890123456")); // Invalid
    }
}
```

### Step 4: Write plugin.yaml

```yaml
name: plugin-rust-validator
version: 1.0.0
description: "Data validation plugin for emails, URLs, phones, and more"
author: "Your Name"
license: MIT
aro-version: ">=0.1.0"

provides:
  - type: rust-plugin
    path: src/
    build:
      cargo-target: release
      output: target/release/libvalidator_plugin.dylib
```

### Step 5: Build and Install

```bash
# Build the plugin
cd Plugins/plugin-rust-validator
cargo build --release

# The library will be at:
# target/release/libvalidator_plugin.dylib (macOS)
# target/release/libvalidator_plugin.so (Linux)
# target/release/validator_plugin.dll (Windows)
```

### Step 6: Use in ARO

With custom actions registered, you use native ARO syntax:

```aro
(Validate User Input: Registration Handler) {
    Extract the <email> from the <request: email>.
    Extract the <phone> from the <request: phone>.

    (* Validate email using custom action - feels native! *)
    <ValidateEmail> the <email-result> from <email>.

    When the <email-result: valid> is false {
        Return a <BadRequest: status> with "Invalid email address".
    }.

    (* Validate phone using custom action *)
    <ValidatePhone> the <phone-result> from <phone>.

    When the <phone-result: valid> is false {
        Return a <BadRequest: status> with "Invalid phone number".
    }.

    (* Validate credit card with options *)
    Extract the <card> from the <request: creditCard>.
    <ValidateCreditCard> the <card-result> from <card>.

    Log "Card type: " with <card-result: card_type> to the <console>.

    Return an <OK: status> with <email-result>.
}
```

The `<ValidateEmail>`, `<ValidatePhone>`, and `<ValidateCreditCard>` actions work exactly like built-in ARO verbs—no `<Call>` required!

## 7.5 Performance Optimization

Rust plugins excel at performance-critical tasks. Here are techniques to maximize speed:

### Compile-Time Regex

Use `once_cell` or `lazy_static` to compile regex patterns once:

```rust
use once_cell::sync::Lazy;
use regex::Regex;

// Compiled once at first use, reused for all calls
static PATTERN: LazyRegex = Lazy::new(|| {
    Regex::new(r"complex pattern").unwrap()
});
```

### Zero-Copy String Handling

When possible, work with borrowed strings:

```rust
fn process_data(input: &str) -> &str {
    // Return a slice instead of allocating
    &input[5..10]
}
```

### SIMD with `memchr`

For searching large data:

```rust
// Cargo.toml
[dependencies]
memchr = "2.6"

// lib.rs
use memchr::memchr;

fn find_delimiter(data: &[u8]) -> Option<usize> {
    memchr(b',', data) // Uses SIMD when available
}
```

### Profile-Guided Optimization

For maximum performance:

```toml
[profile.release]
lto = "fat"           # Full link-time optimization
codegen-units = 1     # Single codegen unit for better optimization
panic = "abort"       # Smaller binary, no unwinding
```

## 7.6 Memory Safety Across FFI

The FFI boundary is where Rust's safety guarantees require extra care.

### Rule: Validate All Pointers

Never trust incoming pointers:

```rust
#[no_mangle]
pub extern "C" fn process(input: *const c_char) -> *mut c_char {
    // ALWAYS check for null
    if input.is_null() {
        return error_result("Null input pointer");
    }

    // ALWAYS use unsafe blocks explicitly
    let input_str = unsafe {
        match CStr::from_ptr(input).to_str() {
            Ok(s) => s,
            Err(_) => return error_result("Invalid UTF-8"),
        }
    };

    // ... process safely ...
}
```

### Rule: Document Memory Ownership

Make it clear who owns what:

```rust
/// Returns a JSON string.
///
/// # Memory
/// The caller is responsible for freeing the returned pointer
/// by calling `aro_plugin_free`.
#[no_mangle]
pub extern "C" fn aro_plugin_execute(...) -> *mut c_char {
    // ...
}

/// Frees memory allocated by plugin functions.
///
/// # Safety
/// The pointer must have been allocated by this plugin.
/// Do not call more than once for the same pointer.
#[no_mangle]
pub extern "C" fn aro_plugin_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}
```

### Rule: No Panics Across FFI

Panics in Rust are undefined behavior when they cross FFI boundaries:

```rust
// WRONG: panic! will cause undefined behavior
#[no_mangle]
pub extern "C" fn dangerous(input: *const c_char) -> *mut c_char {
    let s = unsafe { CStr::from_ptr(input).to_str().unwrap() }; // May panic!
    // ...
}

// CORRECT: Handle errors gracefully
#[no_mangle]
pub extern "C" fn safe(input: *const c_char) -> *mut c_char {
    if input.is_null() {
        return error_result("Null input");
    }

    let s = match unsafe { CStr::from_ptr(input).to_str() } {
        Ok(s) => s,
        Err(_) => return error_result("Invalid UTF-8"),
    };

    // ...
}
```

Use `catch_unwind` for extra safety:

```rust
use std::panic;

#[no_mangle]
pub extern "C" fn protected_function(...) -> *mut c_char {
    let result = panic::catch_unwind(|| {
        // Your code here - panics are caught
        process_data(...)
    });

    match result {
        Ok(value) => value,
        Err(_) => error_result("Internal error"),
    }
}
```

## 7.7 Working with Cargo Dependencies

Rust's ecosystem is one of its greatest strengths. Here are commonly useful crates:

### JSON Handling

```toml
[dependencies]
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
```

```rust
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
struct Request {
    id: u64,
    data: String,
}
```

### Image Processing

```toml
[dependencies]
image = "0.24"
```

```rust
use image::{GenericImageView, ImageFormat};

fn create_thumbnail(data: &[u8]) -> Result<Vec<u8>, String> {
    let img = image::load_from_memory(data)
        .map_err(|e| format!("Failed to load image: {}", e))?;

    let thumbnail = img.thumbnail(200, 200);

    let mut output = Vec::new();
    thumbnail.write_to(&mut std::io::Cursor::new(&mut output), ImageFormat::Png)
        .map_err(|e| format!("Failed to write thumbnail: {}", e))?;

    Ok(output)
}
```

### Cryptography

```toml
[dependencies]
sha2 = "0.10"
hex = "0.4"
```

```rust
use sha2::{Sha256, Digest};

fn hash_data(input: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    let result = hasher.finalize();
    hex::encode(result)
}
```

### HTTP Client

```toml
[dependencies]
ureq = "2.9"
```

```rust
fn fetch_url(url: &str) -> Result<String, String> {
    ureq::get(url)
        .call()
        .map_err(|e| format!("Request failed: {}", e))?
        .into_string()
        .map_err(|e| format!("Failed to read body: {}", e))
}
```

## 7.8 Testing Rust Plugins

Rust's built-in testing makes plugin development reliable:

### Unit Tests

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validation() {
        let input = json!({"value": "test@example.com"});
        let result = validate_email(&input).unwrap();
        assert_eq!(result["valid"], true);
    }

    #[test]
    fn test_edge_cases() {
        // Empty input
        let input = json!({"value": ""});
        let result = validate_email(&input).unwrap();
        assert_eq!(result["valid"], false);

        // Missing field
        let input = json!({});
        let result = validate_email(&input);
        assert!(result.is_err());
    }
}
```

### Integration Tests

Create `tests/integration.rs`:

```rust
use std::ffi::{CStr, CString};

// Import the exported functions
extern "C" {
    fn aro_plugin_execute(
        action: *const i8,
        input: *const i8,
    ) -> *mut i8;
    fn aro_plugin_free(ptr: *mut i8);
}

#[test]
fn test_full_plugin_flow() {
    let action = CString::new("validate-email").unwrap();
    let input = CString::new(r#"{"value": "user@example.com"}"#).unwrap();

    let result_ptr = unsafe {
        aro_plugin_execute(action.as_ptr(), input.as_ptr())
    };

    assert!(!result_ptr.is_null());

    let result = unsafe { CStr::from_ptr(result_ptr) };
    let result_str = result.to_str().unwrap();

    assert!(result_str.contains("\"valid\":true"));

    unsafe { aro_plugin_free(result_ptr) };
}
```

Run tests with:

```bash
cargo test
```

## 7.9 Cross-Platform Considerations

Rust plugins compile to different library formats:

| Platform | Extension | Library Name |
|----------|-----------|--------------|
| macOS | `.dylib` | `libplugin.dylib` |
| Linux | `.so` | `libplugin.so` |
| Windows | `.dll` | `plugin.dll` |

Your `plugin.yaml` should reflect the target platform:

```yaml
provides:
  - type: rust-plugin
    path: src/
    build:
      cargo-target: release
      # macOS
      output: target/release/libvalidator_plugin.dylib
      # Linux: target/release/libvalidator_plugin.so
      # Windows: target/release/validator_plugin.dll
```

For CI/CD, you might build for multiple targets:

```bash
# macOS
cargo build --release

# Linux (cross-compile)
cargo build --release --target x86_64-unknown-linux-gnu

# Windows (cross-compile)
cargo build --release --target x86_64-pc-windows-gnu
```

## 7.10 Best Practices

### Minimize Allocations

Reuse buffers when possible:

```rust
// GOOD: Reuse a single buffer
thread_local! {
    static BUFFER: std::cell::RefCell<Vec<u8>> = std::cell::RefCell::new(Vec::with_capacity(4096));
}

fn process_with_buffer(data: &[u8]) -> Vec<u8> {
    BUFFER.with(|buf| {
        let mut buf = buf.borrow_mut();
        buf.clear();
        buf.extend_from_slice(data);
        // Process...
        buf.clone()
    })
}
```

### Use Error Types

Define clear error types:

```rust
#[derive(Debug)]
enum PluginError {
    NullPointer,
    InvalidUtf8,
    MissingField(String),
    ValidationFailed(String),
}

impl std::fmt::Display for PluginError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PluginError::NullPointer => write!(f, "Null pointer received"),
            PluginError::InvalidUtf8 => write!(f, "Invalid UTF-8 in input"),
            PluginError::MissingField(name) => write!(f, "Missing field: {}", name),
            PluginError::ValidationFailed(msg) => write!(f, "Validation failed: {}", msg),
        }
    }
}
```

### Document FFI Functions

```rust
/// Executes a plugin action.
///
/// # Arguments
/// * `action` - Null-terminated C string with the action name
/// * `input_json` - Null-terminated C string with JSON input
///
/// # Returns
/// Null-terminated C string with JSON result.
/// Returns `{"error": "..."}` on failure.
///
/// # Safety
/// * Both pointers must be valid, non-null, null-terminated C strings
/// * The returned pointer must be freed with `aro_plugin_free`
///
/// # Example
/// ```c
/// char* result = aro_plugin_execute("validate-email", "{\"value\":\"a@b.com\"}");
/// // Use result...
/// aro_plugin_free(result);
/// ```
#[no_mangle]
pub extern "C" fn aro_plugin_execute(...) -> *mut c_char {
    // ...
}
```

## 7.11 Summary

Rust plugins bring systems-programming power to ARO:

- **FFI Interface**: `#[no_mangle]` + `extern "C"` + C types
- **Cargo.toml**: Set `crate-type = ["cdylib"]` for dynamic libraries
- **Memory Safety**: Validate pointers, never panic across FFI, document ownership
- **Performance**: Use `once_cell` for lazy statics, enable LTO, profile your code
- **Testing**: Rust's test framework works seamlessly with plugin code

The combination of Rust's safety guarantees and ARO's expressive syntax creates a powerful platform for building robust, high-performance applications.

Next, we'll explore C plugins—the purest form of the plugin interface.

