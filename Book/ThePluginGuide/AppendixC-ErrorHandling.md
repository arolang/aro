# Appendix C: Error Codes and Handling

This appendix documents the standard error codes, error response format, and error handling patterns for ARO plugins.

## Error Philosophy

ARO follows the principle that **the code is the error message**. When something fails, the error should clearly state what couldn't be done and why. Users shouldn't need to decode cryptic error codes—they should understand immediately what went wrong.

Good error:
```
Cannot validate the <email> from the <validation: validateEmail>.
  Invalid email format: missing @ symbol in "userexample.com"
```

Bad error:
```
Error code 1003
```

## Standard Error Codes

Plugins should use these numeric error codes for the function return value:

| Code | Name | Description |
|------|------|-------------|
| 0 | SUCCESS | Operation completed successfully |
| 1 | GENERAL_ERROR | Unspecified error (see error message) |
| 2 | INVALID_ARGUMENTS | Missing or malformed arguments |
| 3 | ACTION_NOT_FOUND | Requested action doesn't exist |
| 4 | RESOURCE_UNAVAILABLE | External resource not accessible |
| 5 | PERMISSION_DENIED | Operation not permitted |
| 6 | TIMEOUT | Operation timed out |
| 7 | INTERNAL_ERROR | Unexpected plugin error |
| 8 | NOT_IMPLEMENTED | Feature not yet implemented |
| 9 | INVALID_STATE | Operation invalid in current state |
| 10 | RATE_LIMITED | Too many requests |

## Error Response Format

### Basic Error

```json
{
  "error": "Human-readable error message"
}
```

### Detailed Error

```json
{
  "error": "Human-readable error message",
  "code": "ERROR_CODE",
  "details": {
    "field": "email",
    "value": "invalid",
    "reason": "Missing @ symbol"
  }
}
```

### Multiple Errors

For validation or operations that can have multiple failures:

```json
{
  "error": "Validation failed",
  "code": "VALIDATION_ERROR",
  "errors": [
    {
      "code": "INVALID_EMAIL",
      "field": "email",
      "message": "Invalid email format"
    },
    {
      "code": "WEAK_PASSWORD",
      "field": "password",
      "message": "Password must be at least 8 characters"
    }
  ]
}
```

## Domain-Specific Error Codes

### Validation Errors

| Code | Description |
|------|-------------|
| `INVALID_FORMAT` | Value doesn't match expected format |
| `INVALID_LENGTH` | Value too short or too long |
| `INVALID_RANGE` | Numeric value outside allowed range |
| `INVALID_TYPE` | Value has wrong type |
| `REQUIRED_FIELD` | Required field is missing |
| `INVALID_PATTERN` | Value doesn't match regex pattern |

### I/O Errors

| Code | Description |
|------|-------------|
| `CONNECTION_FAILED` | Could not connect to resource |
| `CONNECTION_TIMEOUT` | Connection attempt timed out |
| `READ_ERROR` | Error reading data |
| `WRITE_ERROR` | Error writing data |
| `NOT_FOUND` | Resource not found |
| `ALREADY_EXISTS` | Resource already exists |
| `ACCESS_DENIED` | Permission denied |

### Authentication Errors

| Code | Description |
|------|-------------|
| `INVALID_CREDENTIALS` | Wrong username/password |
| `TOKEN_EXPIRED` | Authentication token has expired |
| `TOKEN_INVALID` | Token is malformed or invalid |
| `SESSION_EXPIRED` | Session has timed out |
| `UNAUTHORIZED` | Not authenticated |
| `FORBIDDEN` | Authenticated but not allowed |

### Rate Limiting Errors

| Code | Description |
|------|-------------|
| `RATE_LIMITED` | Too many requests |
| `QUOTA_EXCEEDED` | Usage quota exceeded |
| `THROTTLED` | Request was throttled |

## Implementing Error Handling

### C Implementation

```c
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

// Error helper
int32_t set_error(char** result_ptr, const char* code, const char* message) {
    char* buffer = malloc(512);
    snprintf(buffer, 512,
        "{\"error\": \"%s\", \"code\": \"%s\"}",
        message, code
    );
    *result_ptr = buffer;
    return 1;
}

// Detailed error helper
int32_t set_detailed_error(
    char** result_ptr,
    const char* code,
    const char* message,
    const char* field,
    const char* value
) {
    char* buffer = malloc(1024);
    snprintf(buffer, 1024,
        "{"
        "  \"error\": \"%s\","
        "  \"code\": \"%s\","
        "  \"details\": {"
        "    \"field\": \"%s\","
        "    \"value\": \"%s\""
        "  }"
        "}",
        message, code, field, value
    );
    *result_ptr = buffer;
    return 1;
}

// Usage
int32_t aro_plugin_execute(
    const char* action_name,
    const char* arguments_json,
    char** result_ptr
) {
    // Parse arguments
    const char* email = get_string_arg(arguments_json, "email");
    if (email == NULL) {
        return set_error(result_ptr, "REQUIRED_FIELD",
            "Missing required argument: email");
    }

    // Validate
    if (!is_valid_email(email)) {
        return set_detailed_error(result_ptr, "INVALID_EMAIL",
            "Invalid email format", "email", email);
    }

    // Success
    *result_ptr = strdup("{\"valid\": true}");
    return 0;
}
```

### Rust Implementation

```rust
use serde::{Deserialize, Serialize};
use serde_json::json;

#[derive(Serialize)]
struct PluginError {
    error: String,
    code: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    details: Option<serde_json::Value>,
}

impl PluginError {
    fn new(code: &str, message: &str) -> Self {
        PluginError {
            error: message.to_string(),
            code: code.to_string(),
            details: None,
        }
    }

    fn with_details(code: &str, message: &str, details: serde_json::Value) -> Self {
        PluginError {
            error: message.to_string(),
            code: code.to_string(),
            details: Some(details),
        }
    }

    fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap()
    }
}

// Usage in execute function
fn execute_action(args: &serde_json::Value) -> Result<serde_json::Value, PluginError> {
    let email = args.get("email")
        .and_then(|v| v.as_str())
        .ok_or_else(|| PluginError::new(
            "REQUIRED_FIELD",
            "Missing required argument: email"
        ))?;

    if !is_valid_email(email) {
        return Err(PluginError::with_details(
            "INVALID_EMAIL",
            "Invalid email format",
            json!({
                "field": "email",
                "value": email,
                "reason": "Missing @ symbol"
            })
        ));
    }

    Ok(json!({"valid": true, "normalized": email.to_lowercase()}))
}

#[no_mangle]
pub extern "C" fn aro_plugin_execute(
    action_name: *const c_char,
    arguments_json: *const c_char,
    result_ptr: *mut *mut c_char
) -> i32 {
    let args: serde_json::Value = parse_args(arguments_json);

    match execute_action(&args) {
        Ok(result) => {
            set_result(result_ptr, &result.to_string());
            0
        }
        Err(e) => {
            set_result(result_ptr, &e.to_json());
            1
        }
    }
}
```

### Swift Implementation

```swift
import Foundation

struct PluginError: Codable {
    let error: String
    let code: String
    let details: [String: String]?

    init(code: String, message: String, details: [String: String]? = nil) {
        self.error = message
        self.code = code
        self.details = details
    }

    func toJSON() -> String {
        let encoder = JSONEncoder()
        let data = try! encoder.encode(self)
        return String(data: data, encoding: .utf8)!
    }
}

enum ActionResult {
    case success(Any)
    case failure(PluginError)
}

func executeAction(args: [String: Any]) -> ActionResult {
    guard let email = args["email"] as? String else {
        return .failure(PluginError(
            code: "REQUIRED_FIELD",
            message: "Missing required argument: email"
        ))
    }

    guard isValidEmail(email) else {
        return .failure(PluginError(
            code: "INVALID_EMAIL",
            message: "Invalid email format",
            details: ["field": "email", "value": email]
        ))
    }

    return .success(["valid": true, "normalized": email.lowercased()])
}

@_cdecl("aro_plugin_execute")
public func pluginExecute(
    _ actionPtr: UnsafePointer<CChar>,
    _ argsPtr: UnsafePointer<CChar>,
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    let args = parseArgs(argsPtr)

    switch executeAction(args: args) {
    case .success(let result):
        let json = try! JSONSerialization.data(withJSONObject: result)
        resultPtr.pointee = strdup(String(data: json, encoding: .utf8)!)
        return 0

    case .failure(let error):
        resultPtr.pointee = strdup(error.toJSON())
        return 1
    }
}
```

## Error Handling in ARO Code

When calling plugins from ARO, handle errors appropriately:

### Check for Errors

```aro
(Validate User Input: Form Handler) {
    <Extract> the <email> from the <body: email>.

    <Call> the <result> from the <validation: validateEmail> with {
        email: <email>
    }.

    <When> <result: error> exists:
        <Log> "Validation failed: " ++ <result: error> to the <console>.
        <Return> a <BadRequest: status> with {
            error: <result: error>,
            code: <result: code>
        }.

    <Return> an <OK: status> with <result>.
}
```

### Handle Multiple Errors

```aro
(Validate Registration: Form Handler) {
    <Extract> the <form-data> from the <body>.

    <Call> the <validation> from the <validation: validateForm> with {
        fields: <form-data>,
        rules: {
            email: { required: true, type: "email" },
            password: { required: true, minLength: 8 }
        }
    }.

    <When> <validation: errors> exists:
        <Return> a <BadRequest: status> with {
            message: "Validation failed",
            errors: <validation: errors>
        }.

    <Return> an <OK: status> with { valid: true }.
}
```

### Error Recovery

```aro
(Fetch With Retry: Data Handler) {
    <Create> the <attempts> with 0.
    <Create> the <max-attempts> with 3.

    <Loop>:
        <Increment> the <attempts>.

        <Call> the <result> from the <http: fetch> with {
            url: "https://api.example.com/data"
        }.

        <When> <result: error> does not exist:
            <Return> an <OK: status> with <result>.

        <When> <attempts> >= <max-attempts>:
            <Return> a <ServerError: status> with {
                error: "Failed after " ++ <max-attempts> ++ " attempts",
                lastError: <result: error>
            }.

        <Log> "Attempt " ++ <attempts> ++ " failed, retrying..." to the <console>.
        <Wait> 1 second.
}
```

## Best Practices

### 1. Be Specific

```json
// Good
{
  "error": "Email validation failed: 'userexample.com' is missing @ symbol",
  "code": "INVALID_EMAIL"
}

// Bad
{
  "error": "Invalid input"
}
```

### 2. Include Context

```json
// Good
{
  "error": "Database connection failed",
  "code": "CONNECTION_FAILED",
  "details": {
    "host": "db.example.com",
    "port": 5432,
    "timeout": 30,
    "reason": "Connection refused"
  }
}
```

### 3. Use Consistent Structure

Always use the same error structure across all actions:

```json
{
  "error": "string",
  "code": "string",
  "details": {}
}
```

### 4. Don't Expose Sensitive Information

```json
// Good
{
  "error": "Authentication failed",
  "code": "INVALID_CREDENTIALS"
}

// Bad
{
  "error": "User 'admin' not found in database users table"
}
```

### 5. Provide Actionable Information

```json
// Good
{
  "error": "Rate limit exceeded. Try again in 60 seconds.",
  "code": "RATE_LIMITED",
  "details": {
    "limit": 100,
    "window": "1 minute",
    "retryAfter": 60
  }
}
```

### 6. Log Detailed Errors Server-Side

Return simplified errors to users but log full details:

```rust
fn handle_database_error(e: DatabaseError) -> PluginError {
    // Log full error for debugging
    eprintln!("Database error: {:?}", e);

    // Return sanitized error to user
    PluginError::new(
        "DATABASE_ERROR",
        "A database error occurred. Please try again later."
    )
}
```

## Error Code Registry

When creating domain-specific error codes, follow this naming convention:

```
{CATEGORY}_{SPECIFIC_ERROR}

Examples:
- VALIDATION_INVALID_FORMAT
- AUTH_TOKEN_EXPIRED
- IO_CONNECTION_FAILED
- RATE_LIMIT_EXCEEDED
```

Document all error codes in your plugin's README:

```markdown
## Error Codes

| Code | Description | Resolution |
|------|-------------|------------|
| `VALIDATION_INVALID_EMAIL` | Email format is invalid | Ensure email contains @ and valid domain |
| `VALIDATION_WEAK_PASSWORD` | Password doesn't meet requirements | Use 8+ characters with mixed case and symbols |
| `AUTH_TOKEN_EXPIRED` | JWT token has expired | Request a new token via refresh endpoint |
```
