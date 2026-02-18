# Chapter 14: Testing Plugins

> *"Testing shows the presence, not the absence of bugs."*
> — Edsger W. Dijkstra

A plugin that works on your machine is a prototype. A plugin that works everywhere—across operating systems, ARO versions, and edge cases—is a product. This chapter covers the testing strategies that transform your plugin from one to the other.

## 14.1 The Testing Pyramid for Plugins

Effective plugin testing operates at multiple levels:

```
                    ┌───────────────┐
                    │   E2E Tests   │   ← Full ARO application
                    │ (Integration) │     with your plugin
                    └───────┬───────┘
                            │
               ┌────────────┴────────────┐
               │    Component Tests      │   ← Plugin + ARO runtime
               │   (Plugin Integration)  │     interaction
               └────────────┬────────────┘
                            │
          ┌─────────────────┴─────────────────┐
          │          Unit Tests               │   ← Individual functions
          │    (C ABI, business logic)        │     in isolation
          └───────────────────────────────────┘
```

Each level catches different classes of bugs:

| Level | Catches | Speed | Stability |
|-------|---------|-------|-----------|
| Unit | Logic errors, edge cases | Fast | High |
| Component | Integration issues, protocol errors | Medium | Medium |
| E2E | Real-world failures, system issues | Slow | Lower |

## 14.2 Unit Testing Plugin Code

Unit tests verify individual functions in isolation. The approach varies by language but follows common patterns.

### Testing Swift Plugins

Use XCTest for Swift plugins:

```swift
// Tests/MyPluginTests/FormatterTests.swift

import XCTest
@testable import FormatterPlugin

final class FormatterTests: XCTestCase {

    // Test helper to simulate C ABI call
    func callAction(_ action: String, args: [String: Any]) throws -> [String: Any] {
        let argsJSON = try JSONSerialization.data(withJSONObject: args)
        let argsString = String(data: argsJSON, encoding: .utf8)!

        var resultPtr: UnsafeMutablePointer<CChar>? = nil

        let status = aro_plugin_execute(
            strdup(action),
            strdup(argsString),
            &resultPtr
        )

        defer { aro_plugin_free(resultPtr) }

        guard status == 0, let ptr = resultPtr else {
            throw TestError.executionFailed(status)
        }

        let resultString = String(cString: ptr)
        let resultData = resultString.data(using: .utf8)!
        return try JSONSerialization.jsonObject(with: resultData) as! [String: Any]
    }

    func testFormatDate() throws {
        let result = try callAction("formatDate", args: [
            "date": "2024-12-25T10:30:00Z",
            "format": "MMMM d, yyyy"
        ])

        XCTAssertEqual(result["formatted"] as? String, "December 25, 2024")
    }

    func testFormatDateInvalidInput() throws {
        let result = try callAction("formatDate", args: [
            "date": "not-a-date",
            "format": "yyyy-MM-dd"
        ])

        XCTAssertNotNil(result["error"])
        XCTAssertTrue((result["error"] as? String)?.contains("parse") ?? false)
    }

    func testFormatCurrency() throws {
        let result = try callAction("formatCurrency", args: [
            "amount": 1234.56,
            "currency": "USD"
        ])

        XCTAssertEqual(result["formatted"] as? String, "$1,234.56")
    }

    func testFormatCurrencyLocale() throws {
        let result = try callAction("formatCurrency", args: [
            "amount": 1234.56,
            "currency": "EUR",
            "locale": "de_DE"
        ])

        // German locale uses comma for decimal, period for thousands
        XCTAssertEqual(result["formatted"] as? String, "1.234,56 €")
    }
}

enum TestError: Error {
    case executionFailed(Int32)
}
```

### Testing Rust Plugins

Use Rust's built-in test framework:

```rust
// src/lib.rs

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    /// Helper to call plugin functions and parse results
    fn call_action(action: &str, args: serde_json::Value) -> Result<serde_json::Value, String> {
        let action_cstr = CString::new(action).unwrap();
        let args_cstr = CString::new(serde_json::to_string(&args).unwrap()).unwrap();
        let mut result_ptr: *mut c_char = std::ptr::null_mut();

        let status = unsafe {
            aro_plugin_execute(
                action_cstr.as_ptr(),
                args_cstr.as_ptr(),
                &mut result_ptr
            )
        };

        let result_str = unsafe { CStr::from_ptr(result_ptr).to_str().unwrap().to_string() };
        unsafe { aro_plugin_free(result_ptr) };

        let result: serde_json::Value = serde_json::from_str(&result_str)
            .map_err(|e| format!("Failed to parse result: {}", e))?;

        if status != 0 {
            Err(result["error"].as_str().unwrap_or("Unknown error").to_string())
        } else {
            Ok(result)
        }
    }

    #[test]
    fn test_validate_email_valid() {
        let result = call_action("validateEmail", json!({
            "email": "user@example.com"
        })).unwrap();

        assert_eq!(result["valid"], true);
    }

    #[test]
    fn test_validate_email_invalid() {
        let result = call_action("validateEmail", json!({
            "email": "not-an-email"
        })).unwrap();

        assert_eq!(result["valid"], false);
        assert!(result["errors"].as_array().unwrap().len() > 0);
    }

    #[test]
    fn test_validate_email_empty() {
        let result = call_action("validateEmail", json!({
            "email": ""
        })).unwrap();

        assert_eq!(result["valid"], false);
    }

    #[test]
    fn test_plugin_info() {
        let info_ptr = unsafe { aro_plugin_info() };
        let info_str = unsafe { CStr::from_ptr(info_ptr).to_str().unwrap() };
        let info: serde_json::Value = serde_json::from_str(info_str).unwrap();

        assert_eq!(info["name"], "validation-plugin");
        assert!(info["actions"].as_array().unwrap().len() > 0);

        unsafe { aro_plugin_free(info_ptr as *mut c_char) };
    }

    // Test memory is properly freed (run with valgrind/ASAN)
    #[test]
    fn test_memory_cleanup() {
        for _ in 0..1000 {
            let _ = call_action("validateEmail", json!({
                "email": "test@example.com"
            }));
        }
        // If there's a memory leak, this will be caught by memory sanitizers
    }
}
```

### Testing C Plugins

For C plugins, use a testing framework like Unity or write minimal test harnesses:

```c
// tests/test_hash.c

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "../src/hash_plugin.h"

// Test helper
int call_action(const char* action, const char* args, char** result) {
    return aro_plugin_execute(action, args, result);
}

void test_djb2_hash() {
    char* result = NULL;
    int status = call_action("djb2", "{\"input\": \"hello\"}", &result);

    assert(status == 0);
    assert(result != NULL);
    assert(strstr(result, "\"hash\"") != NULL);

    // DJB2 hash of "hello" is known
    assert(strstr(result, "261238937") != NULL);

    aro_plugin_free(result);
    printf("test_djb2_hash: PASSED\n");
}

void test_fnv1a_hash() {
    char* result = NULL;
    int status = call_action("fnv1a", "{\"input\": \"hello\"}", &result);

    assert(status == 0);
    assert(result != NULL);

    aro_plugin_free(result);
    printf("test_fnv1a_hash: PASSED\n");
}

void test_empty_input() {
    char* result = NULL;
    int status = call_action("djb2", "{\"input\": \"\"}", &result);

    assert(status == 0);
    // Empty string should still produce a hash (the seed value)

    aro_plugin_free(result);
    printf("test_empty_input: PASSED\n");
}

void test_missing_input() {
    char* result = NULL;
    int status = call_action("djb2", "{}", &result);

    assert(status != 0);  // Should fail
    assert(result != NULL);
    assert(strstr(result, "error") != NULL);

    aro_plugin_free(result);
    printf("test_missing_input: PASSED\n");
}

void test_plugin_info() {
    const char* info = aro_plugin_info();

    assert(info != NULL);
    assert(strstr(info, "hash-plugin") != NULL);
    assert(strstr(info, "djb2") != NULL);
    assert(strstr(info, "fnv1a") != NULL);

    printf("test_plugin_info: PASSED\n");
}

int main() {
    printf("Running hash plugin tests...\n\n");

    test_plugin_info();
    test_djb2_hash();
    test_fnv1a_hash();
    test_empty_input();
    test_missing_input();

    printf("\nAll tests passed!\n");
    return 0;
}
```

Compile and run:
```bash
gcc -o test_hash tests/test_hash.c src/hash_plugin.c -I src/
./test_hash
```

### Testing Python Plugins

Use pytest for Python plugins:

```python
# tests/test_transformer.py

import pytest
import json
import sys
sys.path.insert(0, 'src')

from transformer_plugin import aro_plugin_info, aro_action_generate, aro_action_summarize

class TestPluginInfo:
    def test_returns_valid_json(self):
        info = json.loads(aro_plugin_info())
        assert 'name' in info
        assert 'actions' in info

    def test_lists_all_actions(self):
        info = json.loads(aro_plugin_info())
        action_names = [a['name'] for a in info['actions']]
        assert 'generate' in action_names
        assert 'summarize' in action_names

class TestGenerate:
    def test_basic_generation(self):
        result = json.loads(aro_action_generate(json.dumps({
            "prompt": "Hello, how are",
            "maxTokens": 10
        })))

        assert 'text' in result
        assert len(result['text']) > 0

    def test_respects_max_tokens(self):
        result = json.loads(aro_action_generate(json.dumps({
            "prompt": "Write a story",
            "maxTokens": 5
        })))

        # Token count should be roughly respected
        words = result['text'].split()
        assert len(words) <= 10  # Some margin for tokenization differences

    def test_empty_prompt(self):
        result = json.loads(aro_action_generate(json.dumps({
            "prompt": "",
            "maxTokens": 10
        })))

        # Should handle gracefully, not crash
        assert 'text' in result or 'error' in result

class TestSummarize:
    def test_summarizes_text(self):
        long_text = """
        Machine learning is a subset of artificial intelligence that enables
        computers to learn and improve from experience without being explicitly
        programmed. It focuses on developing algorithms that can access data
        and use it to learn for themselves. The process begins with observations
        or data, such as examples, direct experience, or instruction, to look
        for patterns in data and make better decisions in the future.
        """

        result = json.loads(aro_action_summarize(json.dumps({
            "text": long_text,
            "maxLength": 50
        })))

        assert 'summary' in result
        assert len(result['summary']) < len(long_text)

    def test_short_text_unchanged(self):
        short_text = "Hello world."

        result = json.loads(aro_action_summarize(json.dumps({
            "text": short_text,
            "maxLength": 100
        })))

        # Very short text might just be returned as-is
        assert 'summary' in result

# Fixtures for expensive setup
@pytest.fixture(scope="module")
def model_loaded():
    """Ensure model is loaded once for all tests"""
    # The plugin loads models lazily, but we can warm it up
    aro_action_generate(json.dumps({"prompt": "test", "maxTokens": 1}))
    return True

class TestPerformance:
    def test_generation_time(self, model_loaded, benchmark):
        """Benchmark generation speed"""
        def generate():
            return aro_action_generate(json.dumps({
                "prompt": "The quick brown fox",
                "maxTokens": 20
            }))

        result = benchmark(generate)
        assert 'text' in json.loads(result)
```

Run with pytest:
```bash
pytest tests/ -v --benchmark-disable  # Without benchmarks
pytest tests/ -v                       # With benchmarks
```

## 14.3 Component Testing with ARO

Component tests verify your plugin works correctly with the ARO runtime.

### Writing ARO Test Files

Create `.aro` files specifically for testing:

```aro
(* tests/plugin-tests.aro *)
(* Component tests for the validation plugin *)

(Application-Start: Validation Tests) {
    Log "Running validation plugin component tests..." to the <console>.

    (* Test 1: Email validation - valid *)
    Call the <result1> from the <validation: validateEmail> with {
        email: "test@example.com"
    }.
    Extract the <valid1> from the <result1: valid>.
    When <valid1> is false:
        Log "FAIL: Test 1 - valid email rejected" to the <console: error>.
        Return a <ServerError: status> for the <test-failure>.
    Log "PASS: Test 1 - valid email accepted" to the <console>.

    (* Test 2: Email validation - invalid *)
    Call the <result2> from the <validation: validateEmail> with {
        email: "not-an-email"
    }.
    Extract the <valid2> from the <result2: valid>.
    When <valid2> is true:
        Log "FAIL: Test 2 - invalid email accepted" to the <console: error>.
        Return a <ServerError: status> for the <test-failure>.
    Log "PASS: Test 2 - invalid email rejected" to the <console>.

    (* Test 3: URL validation *)
    Call the <result3> from the <validation: validateURL> with {
        url: "https://example.com/path?query=value"
    }.
    Extract the <valid3> from the <result3: valid>.
    When <valid3> is false:
        Log "FAIL: Test 3 - valid URL rejected" to the <console: error>.
        Return a <ServerError: status> for the <test-failure>.
    Log "PASS: Test 3 - valid URL accepted" to the <console>.

    (* Test 4: Phone validation with locale *)
    Call the <result4> from the <validation: validatePhone> with {
        phone: "+1-555-123-4567",
        locale: "US"
    }.
    Extract the <valid4> from the <result4: valid>.
    When <valid4> is false:
        Log "FAIL: Test 4 - valid US phone rejected" to the <console: error>.
        Return a <ServerError: status> for the <test-failure>.
    Log "PASS: Test 4 - valid US phone accepted" to the <console>.

    Log "" to the <console>.
    Log "All component tests passed!" to the <console>.
    Return an <OK: status> for the <tests>.
}
```

### Running Component Tests

Execute tests using the ARO CLI:

```bash
# Run the test file
aro run ./tests/plugin-tests.aro

# Expected output:
# Running validation plugin component tests...
# PASS: Test 1 - valid email accepted
# PASS: Test 2 - invalid email rejected
# PASS: Test 3 - valid URL accepted
# PASS: Test 4 - valid US phone accepted
#
# All component tests passed!
```

### Test Automation Script

Create a shell script to run all tests:

```bash
#!/bin/bash
# run-tests.sh

set -e

echo "=========================================="
echo "Running Plugin Test Suite"
echo "=========================================="

# Build the plugin
echo ""
echo "Building plugin..."
case "$PLUGIN_TYPE" in
    swift)
        swift build -c release
        ;;
    rust)
        cargo build --release
        ;;
    c)
        make clean && make
        ;;
    python)
        pip install -r requirements.txt
        ;;
esac

# Run unit tests
echo ""
echo "Running unit tests..."
case "$PLUGIN_TYPE" in
    swift)
        swift test
        ;;
    rust)
        cargo test
        ;;
    c)
        ./test_runner
        ;;
    python)
        pytest tests/unit/ -v
        ;;
esac

# Run component tests
echo ""
echo "Running component tests..."
aro run ./tests/plugin-tests.aro

# Run integration tests if present
if [ -f "./tests/integration-tests.aro" ]; then
    echo ""
    echo "Running integration tests..."
    aro run ./tests/integration-tests.aro
fi

echo ""
echo "=========================================="
echo "All tests passed!"
echo "=========================================="
```

## 14.4 Integration and E2E Testing

Integration tests verify your plugin works in realistic scenarios with other components.

### Testing with Mock Services

For plugins that depend on external services, use mocks:

```aro
(* tests/integration-with-mocks.aro *)
(* Test Redis plugin with a mock server *)

(Application-Start: Redis Integration Tests) {
    Log "Starting Redis integration tests..." to the <console>.

    (* Use test Redis instance *)
    Create the <test-prefix> with "test:" ++ <uuid>.

    (* Test 1: Write and read string *)
    Write "test-value" to the <redis: <test-prefix> ++ "string">.
    Read the <value> from the <redis: <test-prefix> ++ "string">.
    When <value> is not "test-value":
        Log "FAIL: String read/write mismatch" to the <console: error>.
        Return a <ServerError: status> for the <test-failure>.
    Log "PASS: String read/write" to the <console>.

    (* Test 2: Write and read object *)
    Create the <test-obj> with { name: "Test", count: 42 }.
    Write <test-obj> to the <redis: <test-prefix> ++ "object">.
    Read the <retrieved> from the <redis: <test-prefix> ++ "object">.
    When <retrieved: name> is not "Test":
        Log "FAIL: Object read/write mismatch" to the <console: error>.
        Return a <ServerError: status> for the <test-failure>.
    Log "PASS: Object read/write" to the <console>.

    (* Test 3: TTL expiration *)
    Write "expiring" to the <redis: <test-prefix> ++ "ttl"> with { ttl: 1 }.
    Wait 2 seconds.
    Read the <expired> from the <redis: <test-prefix> ++ "ttl">.
    When <expired> is not null:
        Log "FAIL: TTL did not expire" to the <console: error>.
        Return a <ServerError: status> for the <test-failure>.
    Log "PASS: TTL expiration" to the <console>.

    (* Cleanup *)
    Call the <keys> from the <redis: list> with { pattern: <test-prefix> ++ "*" }.
    For each <key> in <keys>:
        Write null to the <redis: <key>>.

    Log "All Redis integration tests passed!" to the <console>.
    Return an <OK: status> for the <tests>.
}
```

### End-to-End Application Tests

Test your plugin as part of a complete application:

```aro
(* tests/e2e-user-service.aro *)
(* End-to-end tests for a user service using validation plugin *)

(Application-Start: E2E User Service Tests) {
    Log "Running E2E user service tests..." to the <console>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(* Test endpoint handlers *)

(Test Create User Valid: E2E Tests) {
    (* Simulate HTTP request *)
    Create the <request-body> with {
        email: "newuser@example.com",
        password: "SecureP@ss123",
        name: "New User"
    }.

    (* Call the create user endpoint logic *)
    Call the <email-check> from the <validation: validateEmail> with {
        email: <request-body: email>
    }.
    When <email-check: valid> is false:
        Log "FAIL: Valid email was rejected" to the <console: error>.
        Return a <ServerError: status> for the <test-failure>.

    Call the <password-check> from the <validation: validatePassword> with {
        password: <request-body: password>,
        minLength: 8,
        requireSpecial: true
    }.
    When <password-check: valid> is false:
        Log "FAIL: Valid password was rejected" to the <console: error>.
        Return a <ServerError: status> for the <test-failure>.

    Log "PASS: Create user with valid data" to the <console>.
    Return an <OK: status> for the <test>.
}

(Test Create User Invalid Email: E2E Tests) {
    Create the <request-body> with {
        email: "invalid-email",
        password: "SecureP@ss123",
        name: "Test User"
    }.

    Call the <email-check> from the <validation: validateEmail> with {
        email: <request-body: email>
    }.
    When <email-check: valid> is true:
        Log "FAIL: Invalid email was accepted" to the <console: error>.
        Return a <ServerError: status> for the <test-failure>.

    Log "PASS: Reject invalid email" to the <console>.
    Return an <OK: status> for the <test>.
}

(Test Create User Weak Password: E2E Tests) {
    Create the <request-body> with {
        email: "user@example.com",
        password: "weak",
        name: "Test User"
    }.

    Call the <password-check> from the <validation: validatePassword> with {
        password: <request-body: password>,
        minLength: 8,
        requireSpecial: true
    }.
    When <password-check: valid> is true:
        Log "FAIL: Weak password was accepted" to the <console: error>.
        Return a <ServerError: status> for the <test-failure>.

    Log "PASS: Reject weak password" to the <console>.
    Return an <OK: status> for the <test>.
}
```

## 14.5 Testing Edge Cases and Error Conditions

Robust plugins handle edge cases gracefully.

### Boundary Value Testing

Test at the boundaries of valid input:

```rust
#[cfg(test)]
mod boundary_tests {
    use super::*;

    #[test]
    fn test_max_input_length() {
        // Test with maximum allowed input
        let long_input = "a".repeat(1_000_000);
        let result = call_action("hash", json!({ "input": long_input }));

        // Should succeed or fail gracefully
        assert!(result.is_ok() || result.unwrap_err().contains("too long"));
    }

    #[test]
    fn test_unicode_handling() {
        let inputs = vec![
            "Hello, 世界!",           // Mixed ASCII and CJK
            "🎉🎊🎁",                   // Emoji
            "مرحبا",                   // RTL text
            "\u{0000}null\u{0000}",   // Embedded nulls
            "line1\nline2\rline3",    // Newlines
        ];

        for input in inputs {
            let result = call_action("process", json!({ "input": input }));
            assert!(result.is_ok(), "Failed on input: {:?}", input);
        }
    }

    #[test]
    fn test_numeric_boundaries() {
        // Test with extreme numeric values
        let test_cases = vec![
            (i64::MIN, "min_i64"),
            (i64::MAX, "max_i64"),
            (0, "zero"),
            (-1, "negative_one"),
        ];

        for (value, name) in test_cases {
            let result = call_action("format", json!({ "number": value }));
            assert!(result.is_ok(), "Failed on {}: {:?}", name, value);
        }
    }
}
```

### Error Handling Tests

Verify errors are handled correctly:

```aro
(* tests/error-handling.aro *)

(Application-Start: Error Handling Tests) {
    Log "Testing error handling..." to the <console>.

    (* Test 1: Missing required argument *)
    Call the <result1> from the <formatter: formatDate> with {}.
    When <result1: error> does not exist:
        Log "FAIL: No error for missing argument" to the <console: error>.
        Return a <ServerError: status> for the <test-failure>.
    Log "PASS: Error returned for missing argument" to the <console>.

    (* Test 2: Invalid argument type *)
    Call the <result2> from the <formatter: formatDate> with {
        date: 12345
    }.
    When <result2: error> does not exist:
        Log "FAIL: No error for invalid type" to the <console: error>.
        Return a <ServerError: status> for the <test-failure>.
    Log "PASS: Error returned for invalid type" to the <console>.

    (* Test 3: Malformed JSON in options *)
    Call the <result3> from the <formatter: formatCurrency> with {
        amount: 100,
        options: "not-json"
    }.
    When <result3: error> does not exist:
        Log "FAIL: No error for malformed options" to the <console: error>.
        Return a <ServerError: status> for the <test-failure>.
    Log "PASS: Error returned for malformed options" to the <console>.

    Log "All error handling tests passed!" to the <console>.
    Return an <OK: status> for the <tests>.
}
```

### Memory Safety Tests

For native plugins, test for memory issues:

```bash
# Run with AddressSanitizer (macOS/Linux)
# Swift
swift test -Xswiftc -sanitize=address

# Rust
RUSTFLAGS="-Z sanitizer=address" cargo test

# C/C++
gcc -fsanitize=address -g tests/test_plugin.c src/plugin.c -o test_asan
./test_asan

# Run with Valgrind (Linux)
valgrind --leak-check=full ./test_plugin
```

## 14.6 Continuous Integration

Automate testing with CI/CD pipelines.

### GitHub Actions Example

```yaml
# .github/workflows/test.yml

name: Plugin Tests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test-swift:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build
        run: swift build

      - name: Run Unit Tests
        run: swift test

      - name: Install ARO
        run: |
          curl -fsSL https://get.arolang.dev | sh
          echo "$HOME/.aro/bin" >> $GITHUB_PATH

      - name: Run Component Tests
        run: aro run ./tests/plugin-tests.aro

  test-rust:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Rust
        uses: dtolnay/rust-action@stable

      - name: Build
        run: cargo build --release

      - name: Run Unit Tests
        run: cargo test

      - name: Install ARO
        run: |
          curl -fsSL https://get.arolang.dev | sh
          echo "$HOME/.aro/bin" >> $GITHUB_PATH

      - name: Run Component Tests
        run: aro run ./tests/plugin-tests.aro

  test-python:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.11'

      - name: Install dependencies
        run: pip install -r requirements.txt

      - name: Run Unit Tests
        run: pytest tests/unit/ -v

      - name: Install ARO
        run: |
          curl -fsSL https://get.arolang.dev | sh
          echo "$HOME/.aro/bin" >> $GITHUB_PATH

      - name: Run Component Tests
        run: aro run ./tests/plugin-tests.aro

  cross-platform:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4

      - name: Build and Test
        run: |
          # Platform-specific build commands
          ./build.sh
          ./run-tests.sh
```

### Test Coverage

Track test coverage to ensure comprehensive testing:

```bash
# Rust coverage with tarpaulin
cargo install cargo-tarpaulin
cargo tarpaulin --out Html

# Swift coverage (Xcode)
xcodebuild test -scheme MyPlugin -enableCodeCoverage YES

# Python coverage
pip install coverage
coverage run -m pytest tests/
coverage html
```

## Summary

Testing is what transforms a plugin from "works on my machine" to "works everywhere." The key strategies covered in this chapter:

- **Unit tests**: Verify individual functions in isolation
- **Component tests**: Verify plugin/ARO runtime integration
- **E2E tests**: Verify realistic application scenarios
- **Edge case tests**: Verify boundary conditions and error handling
- **Memory safety tests**: Verify no leaks or corruption (native plugins)
- **CI/CD integration**: Automate testing on every change

A well-tested plugin inspires confidence. Users trust it, contributors can modify it safely, and you can release updates without fear. The investment in testing pays dividends throughout the plugin's lifetime.

In the next chapter, we'll explore how to share your tested, polished plugin with the world through publishing and documentation.
