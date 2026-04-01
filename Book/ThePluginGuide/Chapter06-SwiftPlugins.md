# Chapter 6: Swift Plugins

*"Swift is more than a language—it's an ecosystem."*

---

Swift is the native language of ARO, so Swift plugins feel natural. You get full access to Foundation, seamless async/await integration, and the entire Swift Package ecosystem. This chapter takes you from your first Swift plugin to production-ready code with external dependencies.

## 6.1 Why Swift?

Swift plugins offer several advantages:

**Native Integration**: ARO itself is written in Swift. Swift plugins share memory space with the runtime, enabling efficient data exchange without serialization overhead.

**Rich Standard Library**: Foundation provides date formatting, string manipulation, regular expressions, networking, and more—all immediately available.

**Apple Ecosystem**: For applications targeting Apple platforms, Swift plugins can access CoreFoundation, Security, and other system frameworks.

**Swift Package Manager**: Need a third-party library? SPM integration means adding dependencies is a single line in `Package.swift`.

**Async/Await**: Swift's native concurrency model works seamlessly with ARO's async execution engine.

## 6.2 Plugin Structure: Single-File vs. Package

Swift plugins come in two forms:

### Single-File Plugins

For simple plugins without external dependencies:

```
Plugins/
└── plugin-swift-formatter/
    ├── plugin.yaml
    └── Sources/
        └── FormatterPlugin.swift
```

ARO compiles single `.swift` files directly using `swiftc`.

### Package Plugins

For plugins with dependencies or multiple source files:

```
Plugins/
└── plugin-swift-database/
    ├── plugin.yaml
    ├── Package.swift
    └── Sources/
        └── DatabasePlugin/
            ├── DatabasePlugin.swift
            └── QueryBuilder.swift
```

Package plugins are built using `swift build`, enabling full SPM integration.

## 6.3 The C ABI Bridge

Here's the key insight: despite being Swift, plugins communicate with ARO through a C-compatible interface. This is what makes the plugin system language-agnostic.

Swift provides the `@_cdecl` attribute to export functions with C calling conventions:

```swift
@_cdecl("aro_plugin_init")
public func pluginInit() -> UnsafePointer<CChar> {
    // Return JSON metadata
}
```

The `@_cdecl` attribute:
- Exports the function with the specified C symbol name
- Uses C calling conventions (no Swift ABI features)
- Makes the function visible to `dlsym` when the library is loaded

## 6.4 Your First Swift Plugin: Custom Actions

Let's build a date formatting plugin. It will format dates according to locale and provide relative time descriptions like "2 hours ago."

### Step 1: Create the Directory Structure

```
Plugins/
└── plugin-swift-datetime/
    ├── plugin.yaml
    └── Sources/
        └── DateTimePlugin.swift
```

### Step 2: Write the Manifest

```yaml
# plugin.yaml
name: plugin-swift-datetime
version: 1.0.0
description: "Date and time formatting with locale support"
author: "Your Name"
license: MIT
aro-version: ">=0.1.0"

provides:
  - type: swift-plugin
    path: Sources/
    actions:
      - name: FormatDate
        role: own
        verbs: [formatdate, format]
        prepositions: [from, with]
        description: Format a date according to a pattern and locale
      - name: ParseDate
        role: own
        verbs: [parsedate]
        prepositions: [from, with]
        description: Parse a date string into a timestamp
      - name: RelativeDate
        role: own
        verbs: [relativedate, relative]
        prepositions: [from]
        description: Generate relative time description
```

### Step 3: Implement the Plugin

```swift
// DateTimePlugin.swift
import Foundation

// MARK: - Plugin Initialization

/// Returns plugin metadata as JSON
/// This function is called once when the plugin is loaded.
@_cdecl("aro_plugin_info")
public func pluginInfo() -> UnsafePointer<CChar> {
    let metadata = """
    {
        "name": "plugin-swift-datetime",
        "version": "1.0.0",
        "actions": [
            {
                "name": "FormatDate",
                "role": "own",
                "verbs": ["formatdate", "format"],
                "prepositions": ["from", "with"]
            },
            {
                "name": "ParseDate",
                "role": "own",
                "verbs": ["parsedate"],
                "prepositions": ["from", "with"]
            },
            {
                "name": "RelativeDate",
                "role": "own",
                "verbs": ["relativedate", "relative"],
                "prepositions": ["from"]
            }
        ]
    }
    """
    return strdup(metadata)!
}

// MARK: - Service Implementation

/// Main service entry point
///
/// - Parameters:
///   - methodPtr: C string with the method name
///   - argsPtr: C string with JSON arguments
///   - resultPtr: Pointer where to store the result JSON
/// - Returns: 0 for success, non-zero for error
@_cdecl("datetime_call")
public func datetimeCall(
    _ methodPtr: UnsafePointer<CChar>,
    _ argsPtr: UnsafePointer<CChar>,
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    let method = String(cString: methodPtr)
    let argsJSON = String(cString: argsPtr)

    // Parse arguments
    guard let argsData = argsJSON.data(using: .utf8),
          let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] else {
        return setError(resultPtr, "Invalid JSON arguments")
    }

    // Dispatch to the appropriate method
    do {
        let result: [String: Any]

        switch method {
        case "format":
            result = try formatDate(args)
        case "parse":
            result = try parseDate(args)
        case "relative":
            result = try relativeDate(args)
        case "now":
            result = getCurrentTime()
        default:
            return setError(resultPtr, "Unknown method: \(method)")
        }

        // Serialize result to JSON
        let resultData = try JSONSerialization.data(withJSONObject: result)
        let resultJSON = String(data: resultData, encoding: .utf8)!
        resultPtr.pointee = strdup(resultJSON)
        return 0

    } catch {
        return setError(resultPtr, error.localizedDescription)
    }
}

// MARK: - Method Implementations

/// Format a date according to the specified format and locale
private func formatDate(_ args: [String: Any]) throws -> [String: Any] {
    guard let timestamp = args["timestamp"] as? TimeInterval else {
        throw PluginError.missingParameter("timestamp")
    }

    let format = args["format"] as? String ?? "yyyy-MM-dd HH:mm:ss"
    let localeIdentifier = args["locale"] as? String ?? "en_US"

    let date = Date(timeIntervalSince1970: timestamp)
    let formatter = DateFormatter()
    formatter.dateFormat = format
    formatter.locale = Locale(identifier: localeIdentifier)

    let formatted = formatter.string(from: date)

    return [
        "formatted": formatted,
        "timestamp": timestamp,
        "format": format,
        "locale": localeIdentifier
    ]
}

/// Parse a date string into a timestamp
private func parseDate(_ args: [String: Any]) throws -> [String: Any] {
    guard let dateString = args["date"] as? String else {
        throw PluginError.missingParameter("date")
    }

    let format = args["format"] as? String ?? "yyyy-MM-dd"
    let localeIdentifier = args["locale"] as? String ?? "en_US"

    let formatter = DateFormatter()
    formatter.dateFormat = format
    formatter.locale = Locale(identifier: localeIdentifier)

    guard let date = formatter.date(from: dateString) else {
        throw PluginError.parseError("Could not parse '\(dateString)' with format '\(format)'")
    }

    return [
        "timestamp": date.timeIntervalSince1970,
        "date": dateString,
        "format": format
    ]
}

/// Generate a relative time description
private func relativeDate(_ args: [String: Any]) throws -> [String: Any] {
    guard let timestamp = args["timestamp"] as? TimeInterval else {
        throw PluginError.missingParameter("timestamp")
    }

    let date = Date(timeIntervalSince1970: timestamp)
    let now = Date()

    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full

    if let localeIdentifier = args["locale"] as? String {
        formatter.locale = Locale(identifier: localeIdentifier)
    }

    let relative = formatter.localizedString(for: date, relativeTo: now)

    return [
        "relative": relative,
        "timestamp": timestamp,
        "now": now.timeIntervalSince1970
    ]
}

/// Get the current time
private func getCurrentTime() -> [String: Any] {
    let now = Date()
    let formatter = ISO8601DateFormatter()

    return [
        "timestamp": now.timeIntervalSince1970,
        "iso8601": formatter.string(from: now),
        "unix": Int(now.timeIntervalSince1970)
    ]
}

// MARK: - Error Handling

/// Set an error result and return failure code
private func setError(
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ message: String
) -> Int32 {
    let errorJSON = "{\"error\": \"\(message.replacingOccurrences(of: "\"", with: "\\\""))\"}"
    resultPtr.pointee = strdup(errorJSON)
    return 1
}

/// Plugin errors
private enum PluginError: LocalizedError {
    case missingParameter(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .missingParameter(let name):
            return "Missing required parameter: \(name)"
        case .parseError(let message):
            return message
        }
    }
}
```

### Step 4: Use the Plugin in ARO

With custom actions registered, use natural ARO syntax:

```aro
(Show Timestamps: Application-Start) {
    Create the <now> with { timestamp: 1707660600 }.

    (* Format using the FormatDate action - feels native! *)
    <FormatDate> the <formatted> from the <now: timestamp> with {
        format: "EEEE, MMMM d, yyyy",
        locale: "en_US"
    }.
    Log "Formatted: " with <formatted: formatted> to the <console>.

    (* Get relative time using RelativeDate action *)
    Compute the <past> from <now: timestamp> - 7200.
    <RelativeDate> the <relative> from the <past>.
    Log <relative: relative> to the <console>.

    (* Parse a date string back to timestamp *)
    <ParseDate> the <parsed> from "2026-02-11" with {
        format: "yyyy-MM-dd"
    }.
    Log "Parsed timestamp: " with <parsed: timestamp> to the <console>.

    Return an <OK: status> for the <startup>.
}
```

Output:
```
Formatted: Tuesday, February 11, 2026
2 hours ago
Parsed timestamp: 1707609600
```

The `<FormatDate>`, `<ParseDate>`, and `<RelativeDate>` actions work exactly like built-in ARO verbs—no `<Call>` needed!

## 6.5 Working with Foundation Types

Swift plugins can leverage Foundation's rich type system. Here's a currency formatting plugin:

```swift
import Foundation

@_cdecl("currency_call")
public func currencyCall(
    _ methodPtr: UnsafePointer<CChar>,
    _ argsPtr: UnsafePointer<CChar>,
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    let method = String(cString: methodPtr)
    guard let args = parseJSON(String(cString: argsPtr)) else {
        return setError(resultPtr, "Invalid JSON")
    }

    switch method {
    case "format":
        guard let amount = args["amount"] as? Double else {
            return setError(resultPtr, "Missing 'amount'")
        }

        let currencyCode = args["currency"] as? String ?? "USD"
        let localeIdentifier = args["locale"] as? String ?? "en_US"

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.locale = Locale(identifier: localeIdentifier)

        guard let formatted = formatter.string(from: NSNumber(value: amount)) else {
            return setError(resultPtr, "Formatting failed")
        }

        return setResult(resultPtr, ["formatted": formatted, "amount": amount])

    case "parse":
        guard let text = args["text"] as? String else {
            return setError(resultPtr, "Missing 'text'")
        }

        let localeIdentifier = args["locale"] as? String ?? "en_US"

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: localeIdentifier)

        guard let number = formatter.number(from: text) else {
            return setError(resultPtr, "Could not parse '\(text)'")
        }

        return setResult(resultPtr, [
            "amount": number.doubleValue,
            "text": text
        ])

    default:
        return setError(resultPtr, "Unknown method: \(method)")
    }
}

// Helper functions
private func parseJSON(_ json: String) -> [String: Any]? {
    guard let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return obj
}

private func setResult(_ ptr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                       _ value: [String: Any]) -> Int32 {
    guard let data = try? JSONSerialization.data(withJSONObject: value),
          let json = String(data: data, encoding: .utf8) else {
        return setError(ptr, "Serialization failed")
    }
    ptr.pointee = strdup(json)
    return 0
}

private func setError(_ ptr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                      _ msg: String) -> Int32 {
    ptr.pointee = strdup("{\"error\":\"\(msg)\"}")
    return 1
}
```

Usage in ARO (with custom action `<FormatCurrency>`):

```aro
(Format Invoice: Invoice Handler) {
    Extract the <amount> from the <invoice: total>.

    (* Use the FormatCurrency custom action *)
    <FormatCurrency> the <formatted> from <amount> with {
        currency: "EUR",
        locale: "de_DE"
    }.

    Log "Total: " with <formatted: formatted> to the <console>.
    (* Output: Total: 1.234,56 € *)

    Return an <OK: status> with <formatted>.
}
```

## 6.6 Package Plugins with Dependencies

When you need external libraries, create a Swift package:

### Directory Structure

```
Plugins/
└── plugin-swift-uuid/
    ├── plugin.yaml
    ├── Package.swift
    └── Sources/
        └── UUIDPlugin/
            └── UUIDPlugin.swift
```

### Package.swift

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UUIDPlugin",
    platforms: [.macOS(.v12)],
    products: [
        .library(
            name: "UUIDPlugin",
            type: .dynamic,
            targets: ["UUIDPlugin"]
        )
    ],
    dependencies: [
        // Add external dependencies here
    ],
    targets: [
        .target(
            name: "UUIDPlugin",
            dependencies: []
        )
    ]
)
```

**Important**: Set `type: .dynamic` in the library product. This ensures Swift Package Manager builds a dynamic library (`.dylib`) that ARO can load at runtime.

### plugin.yaml

```yaml
name: plugin-swift-uuid
version: 1.0.0
description: "UUID generation with multiple formats"
aro-version: ">=0.1.0"

provides:
  - type: swift-plugin
    path: Sources/

build:
  swift:
    minimum-version: "6.2"
    targets:
      - name: UUIDPlugin
        path: Sources/
```

### Adding a Real Dependency

Here's an example using a hypothetical cryptography library:

```swift
// Package.swift
import PackageDescription

let package = Package(
    name: "CryptoPlugin",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "CryptoPlugin", type: .dynamic, targets: ["CryptoPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "CryptoPlugin",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ]
        )
    ]
)
```

```swift
// CryptoPlugin.swift
import Foundation
import Crypto

@_cdecl("crypto_call")
public func cryptoCall(
    _ methodPtr: UnsafePointer<CChar>,
    _ argsPtr: UnsafePointer<CChar>,
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    let method = String(cString: methodPtr)
    let argsJSON = String(cString: argsPtr)

    guard let data = argsJSON.data(using: .utf8),
          let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return setError(resultPtr, "Invalid JSON")
    }

    switch method {
    case "sha256":
        guard let input = args["data"] as? String else {
            return setError(resultPtr, "Missing 'data'")
        }

        let inputData = Data(input.utf8)
        let hash = SHA256.hash(data: inputData)
        let hashString = hash.map { String(format: "%02x", $0) }.joined()

        return setResult(resultPtr, [
            "hash": hashString,
            "algorithm": "SHA256",
            "input_length": input.count
        ])

    case "hmac":
        guard let message = args["message"] as? String,
              let key = args["key"] as? String else {
            return setError(resultPtr, "Missing 'message' or 'key'")
        }

        let keyData = SymmetricKey(data: Data(key.utf8))
        let messageData = Data(message.utf8)
        let authCode = HMAC<SHA256>.authenticationCode(for: messageData, using: keyData)
        let hmacString = Data(authCode).map { String(format: "%02x", $0) }.joined()

        return setResult(resultPtr, [
            "hmac": hmacString,
            "algorithm": "HMAC-SHA256"
        ])

    default:
        return setError(resultPtr, "Unknown method: \(method)")
    }
}
```

## 6.7 Async Operations in Swift Plugins

Swift plugins can perform async operations, but the plugin interface is synchronous. Use `Task` and semaphores for blocking:

```swift
import Foundation

@_cdecl("network_call")
public func networkCall(
    _ methodPtr: UnsafePointer<CChar>,
    _ argsPtr: UnsafePointer<CChar>,
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    let method = String(cString: methodPtr)
    let argsJSON = String(cString: argsPtr)

    guard let args = parseJSON(argsJSON) else {
        return setError(resultPtr, "Invalid JSON")
    }

    // Use a semaphore to wait for async completion
    let semaphore = DispatchSemaphore(value: 0)
    var asyncResult: [String: Any]?
    var asyncError: String?

    Task {
        do {
            switch method {
            case "fetch":
                asyncResult = try await fetchURL(args)
            default:
                asyncError = "Unknown method: \(method)"
            }
        } catch {
            asyncError = error.localizedDescription
        }
        semaphore.signal()
    }

    // Wait with timeout
    let timeout = DispatchTime.now() + .seconds(30)
    if semaphore.wait(timeout: timeout) == .timedOut {
        return setError(resultPtr, "Request timed out")
    }

    if let error = asyncError {
        return setError(resultPtr, error)
    }

    if let result = asyncResult {
        return setResult(resultPtr, result)
    }

    return setError(resultPtr, "No result")
}

private func fetchURL(_ args: [String: Any]) async throws -> [String: Any] {
    guard let urlString = args["url"] as? String,
          let url = URL(string: urlString) else {
        throw PluginError.invalidParameter("url")
    }

    let (data, response) = try await URLSession.shared.data(from: url)

    guard let httpResponse = response as? HTTPURLResponse else {
        throw PluginError.networkError("Invalid response")
    }

    return [
        "status": httpResponse.statusCode,
        "body": String(data: data, encoding: .utf8) ?? "",
        "content_length": data.count
    ]
}

private enum PluginError: LocalizedError {
    case invalidParameter(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidParameter(let name): return "Invalid parameter: \(name)"
        case .networkError(let msg): return "Network error: \(msg)"
        }
    }
}
```

**Caution**: Blocking async operations in plugins should be used sparingly. For heavy async workloads, consider whether a different architecture (like a background service) might be more appropriate.

## 6.8 Memory Management

Swift's ARC handles most memory management automatically, but the C interface requires special attention:

### Rule: `strdup` for Return Values

When returning strings through the C interface, use `strdup`:

```swift
// CORRECT: strdup creates a new allocation that ARO can free
resultPtr.pointee = strdup(jsonString)

// WRONG: This pointer may be invalidated when the Swift string is deallocated
resultPtr.pointee = jsonString.withCString { $0 }
```

ARO calls `free()` on the returned pointer after reading it. Using `strdup` ensures the memory is allocated in a way that `free()` can safely deallocate.

### Rule: Don't Hold References Across Calls

Each plugin call should be stateless:

```swift
// WRONG: Storing state between calls
private var sessionData: [String: Any] = [:]

@_cdecl("session_call")
public func sessionCall(...) -> Int32 {
    // This will cause thread safety issues
    sessionData["key"] = value
}

// CORRECT: Return all state in the response
@_cdecl("session_call")
public func sessionCall(...) -> Int32 {
    // Include all necessary data in the result
    return setResult(resultPtr, ["session_id": "...", "data": [...]])
}
```

If you need persistent state, use thread-safe storage:

```swift
import Foundation

private let stateLock = NSLock()
private var globalState: [String: Any] = [:]

@_cdecl("stateful_call")
public func statefulCall(...) -> Int32 {
    stateLock.lock()
    defer { stateLock.unlock() }

    // Safe to access globalState here
}
```

## 6.9 Best Practices

### Keep Plugins Focused

One plugin, one responsibility:

```swift
// GOOD: Focused on date/time formatting
"name": "datetime"
"methods": ["format", "parse", "relative"]

// AVOID: Kitchen sink plugin
"name": "utilities"
"methods": ["formatDate", "parseCSV", "compressFile", "sendEmail"]
```

### Validate Input Early

Check all required parameters before processing:

```swift
@_cdecl("service_call")
public func serviceCall(...) -> Int32 {
    guard let args = parseJSON(argsJSON) else {
        return setError(resultPtr, "Invalid JSON arguments")
    }

    // Validate required fields
    guard let requiredField = args["field"] as? String else {
        return setError(resultPtr, "Missing required field: 'field'")
    }

    guard !requiredField.isEmpty else {
        return setError(resultPtr, "Field 'field' cannot be empty")
    }

    // Now proceed with processing...
}
```

### Return Structured Errors

Include enough context for debugging:

```swift
private func setError(_ ptr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                      _ message: String,
                      code: String? = nil) -> Int32 {
    var error: [String: Any] = ["error": message]
    if let code = code {
        error["code"] = code
    }

    guard let data = try? JSONSerialization.data(withJSONObject: error),
          let json = String(data: data, encoding: .utf8) else {
        ptr.pointee = strdup("{\"error\":\"Unknown error\"}")
        return 1
    }

    ptr.pointee = strdup(json)
    return 1
}

// Usage
return setError(resultPtr, "User not found", code: "USER_NOT_FOUND")
```

### Document Your Methods

The `methods` array in your init metadata helps users discover available operations:

```swift
@_cdecl("aro_plugin_init")
public func pluginInit() -> UnsafePointer<CChar> {
    let metadata = """
    {
        "services": [
            {
                "name": "datetime",
                "symbol": "datetime_call",
                "methods": ["format", "parse", "relative", "now", "add", "diff"],
                "description": "Date and time manipulation"
            }
        ]
    }
    """
    return strdup(metadata)!
}
```

## 6.10 Summary

Swift plugins combine the power of Apple's ecosystem with ARO's extensibility:

- **`@_cdecl`** exports functions with C calling conventions
- **Single-file plugins** for simple cases, **package plugins** for dependencies
- **Foundation types** (DateFormatter, NumberFormatter, etc.) handle common formatting
- **SPM integration** enables using any Swift package
- **Memory**: Use `strdup` for return values, keep calls stateless

The C ABI bridge adds a thin layer of complexity, but the payoff is access to Swift's entire ecosystem from your ARO applications.

Next, we'll explore Rust plugins—where performance meets safety.

