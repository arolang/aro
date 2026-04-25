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

## 6.3 The AROPluginKit SDK

While you *can* write all the `@_cdecl` exports by hand, the **AROPluginKit** SDK eliminates the boilerplate. Import it via Swift Package Manager:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/arolang/aro-plugin-sdk-swift.git", branch: "main"),
],
targets: [
    .target(name: "MyPlugin", dependencies: [
        .product(name: "AROPluginKit", package: "aro-plugin-sdk-swift"),
    ]),
]
```

Then declare your plugin with the builder API and the `@AROExport` macro:

```swift
import AROPluginKit

@AROExport
private let plugin = AROPlugin(name: "my-plugin", version: "1.0.0", handle: "My")
    .action("Greet", verbs: ["greet"], role: "own", prepositions: ["with"],
            description: "Generate a greeting") { input in
        let name = input.string("name") ?? "World"
        return .success(["greeting": "Hello, \(name)!"])
    }
    .qualifier("reverse", inputTypes: ["List", "String"],
               description: "Reverse elements") { params in
        if let arr = params.arrayValue { return .success(Array(arr.reversed())) }
        if let str = params.stringValue { return .success(String(str.reversed())) }
        return .failure("reverse requires a list or string")
    }
    .service("math", methods: ["add", "multiply"]) { method, input in
        let a = input.with.double("a") ?? 0
        let b = input.with.double("b") ?? 0
        switch method {
        case "add": return .success(["result": a + b])
        case "multiply": return .success(["result": a * b])
        default: return .failure(.notFound, "Unknown method: \(method)")
        }
    }
    .onInit { /* one-time setup */ }
    .onShutdown { /* cleanup */ }
```

That's the entire plugin. The SDK auto-generates all C ABI exports (`aro_plugin_info`, `aro_plugin_execute`, `aro_plugin_qualifier`, `aro_plugin_free`, etc.), and the `@AROExport` macro generates the registration entry point that the ARO runtime calls to initialize the plugin.

### Registration Across Languages

Every language has a native, idiomatic way to register plugins:

| Language | Registration | Generated Exports |
|----------|-------------|-------------------|
| **Swift** | `@AROExport` macro | `aro_plugin_register` + all C ABI |
| **Rust** | `#[no_mangle] extern "C"` functions | Manual C ABI |
| **C** | `ARO_PLUGIN()` + `ARO_ACTION()` macros | Automatic via header |
| **Python** | `@plugin` + `@action` decorators + `export_abi()` | Automatic via SDK |

## 6.4 Your First Swift Plugin: Custom Actions

Let's build a greeting plugin using the SDK.

### Step 1: Create the Directory Structure

```
Plugins/
└── plugin-swift-greeting/
    ├── plugin.yaml
    ├── Package.swift
    └── Sources/
        └── GreetingPlugin.swift
```

### Step 2: Write the Manifest and Package.swift

```yaml
# plugin.yaml
name: plugin-swift-greeting
version: 1.0.0
handle: Greeting
provides:
  - type: swift-plugin
    path: Sources/
```

```swift
// Package.swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GreetingPlugin",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "GreetingPlugin", type: .dynamic, targets: ["GreetingPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/arolang/aro-plugin-sdk-swift.git", branch: "main"),
    ],
    targets: [
        .target(name: "GreetingPlugin", dependencies: [
            .product(name: "AROPluginKit", package: "aro-plugin-sdk-swift"),
        ]),
    ]
)
```

### Step 3: Implement the Plugin

```swift
// GreetingPlugin.swift
import Foundation
import AROPluginKit

@AROExport
private let plugin = AROPlugin(name: "plugin-swift-greeting", version: "1.0.0", handle: "Greeting")
    .action("Greet", verbs: ["greet"], role: "own", prepositions: ["with"],
            description: "Generate a greeting message") { input in
        let name = input.string("name") ?? input.with.string("name") ?? "World"
        return .success(["greeting": "Hello, \(name)!"])
    }
    .action("Farewell", verbs: ["farewell"], role: "own", prepositions: ["with"],
            description: "Generate a farewell message") { input in
        let name = input.string("name") ?? input.with.string("name") ?? "World"
        return .success(["farewell": "Goodbye, \(name)!"])
    }
```

That's it. No manual JSON, no `@_cdecl`, no memory management. The `@AROExport` macro and the SDK handle everything.

// MARK: - Method Implementations

/// Format a date according to the specified format and locale.
/// The primary value comes from the main input; options come from _with params.
private func formatDate(_ args: [String: Any], params: [String: Any]) throws -> [String: Any] {
    guard let timestamp = args["data"] as? TimeInterval ?? args["timestamp"] as? TimeInterval else {
        throw PluginError.missingParameter("timestamp")
    }

    let format = params["format"] as? String ?? args["format"] as? String ?? "yyyy-MM-dd HH:mm:ss"
    let localeIdentifier = params["locale"] as? String ?? args["locale"] as? String ?? "en_US"

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

/// Parse a date string into a timestamp.
/// The primary value comes from the main input; format and locale from _with params.
private func parseDate(_ args: [String: Any], params: [String: Any]) throws -> [String: Any] {
    guard let dateString = args["data"] as? String ?? args["date"] as? String else {
        throw PluginError.missingParameter("date")
    }

    let format = params["format"] as? String ?? args["format"] as? String ?? "yyyy-MM-dd"
    let localeIdentifier = params["locale"] as? String ?? args["locale"] as? String ?? "en_US"

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
    guard let timestamp = args["data"] as? TimeInterval ?? args["timestamp"] as? TimeInterval else {
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

// MARK: - Free

/// Frees memory allocated by the plugin. REQUIRED.
@_cdecl("aro_plugin_free")
public func pluginFree(_ ptr: UnsafeMutablePointer<CChar>?) {
    ptr.map { free($0) }
}

// MARK: - Error Handling

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

Swift plugins can leverage Foundation's rich type system. Here's a currency formatting plugin. Notice that `aro_plugin_execute` now takes two parameters and returns `UnsafeMutablePointer<CChar>` directly—no out-pointer or integer return code:

```swift
import Foundation

@_cdecl("aro_plugin_info")
public func pluginInfo() -> UnsafePointer<CChar> {
    return strdup("""
    {
        "name": "plugin-swift-currency",
        "version": "1.0.0",
        "actions": [
            {
                "name": "FormatCurrency",
                "role": "own",
                "verbs": ["formatcurrency"],
                "prepositions": ["from", "with"]
            }
        ]
    }
    """)!
}

@_cdecl("aro_plugin_execute")
public func pluginExecute(
    _ actionPtr: UnsafePointer<CChar>,
    _ inputPtr: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
    let action = String(cString: actionPtr)
    guard let args = parseJSON(String(cString: inputPtr)) else {
        return strdup("{\"error\":\"Invalid JSON\"}")!
    }

    // _with parameters (from the `with { }` clause)
    let withParams = args["_with"] as? [String: Any] ?? [:]

    switch action {
    case "format-currency", "formatcurrency":
        guard let amount = (args["data"] as? Double) ?? (args["amount"] as? Double) else {
            return strdup("{\"error\":\"Missing 'amount'\"}")!
        }

        let currencyCode = withParams["currency"] as? String ?? args["currency"] as? String ?? "USD"
        let localeIdentifier = withParams["locale"] as? String ?? args["locale"] as? String ?? "en_US"

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.locale = Locale(identifier: localeIdentifier)

        guard let formatted = formatter.string(from: NSNumber(value: amount)) else {
            return strdup("{\"error\":\"Formatting failed\"}")!
        }

        return jsonResult(["formatted": formatted, "amount": amount])

    default:
        return strdup("{\"error\":\"Unknown action: \(action)\"}")!
    }
}

@_cdecl("aro_plugin_free")
public func pluginFree(_ ptr: UnsafeMutablePointer<CChar>?) {
    ptr.map { free($0) }
}

// Helper functions
private func parseJSON(_ json: String) -> [String: Any]? {
    guard let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return obj
}

private func jsonResult(_ value: [String: Any]) -> UnsafeMutablePointer<CChar> {
    guard let data = try? JSONSerialization.data(withJSONObject: value),
          let json = String(data: data, encoding: .utf8) else {
        return strdup("{\"error\":\"Serialization failed\"}")!
    }
    return strdup(json)!
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

@_cdecl("aro_plugin_execute")
public func pluginExecute(
    _ actionPtr: UnsafePointer<CChar>,
    _ inputPtr: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
    let action = String(cString: actionPtr)
    let inputJSON = String(cString: inputPtr)

    guard let inputData = inputJSON.data(using: .utf8),
          let args = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] else {
        return strdup("{\"error\":\"Invalid JSON\"}")!
    }

    switch action {
    case "sha256":
        guard let input = args["data"] as? String else {
            return strdup("{\"error\":\"Missing 'data'\"}")!
        }

        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        let hashString = hash.map { String(format: "%02x", $0) }.joined()

        return jsonResult([
            "hash": hashString,
            "algorithm": "SHA256",
            "input_length": input.count
        ])

    case "hmac":
        guard let message = args["data"] as? String,
              let key = (args["_with"] as? [String: Any])?["key"] as? String
                        ?? args["key"] as? String else {
            return strdup("{\"error\":\"Missing 'data' or 'key'\"}")!
        }

        let keyData = SymmetricKey(data: Data(key.utf8))
        let messageData = Data(message.utf8)
        let authCode = HMAC<SHA256>.authenticationCode(for: messageData, using: keyData)
        let hmacString = Data(authCode).map { String(format: "%02x", $0) }.joined()

        return jsonResult([
            "hmac": hmacString,
            "algorithm": "HMAC-SHA256"
        ])

    default:
        return strdup("{\"error\":\"Unknown action: \(action)\"}")!
    }
}
```

## 6.7 Async Operations in Swift Plugins

Swift plugins can perform async operations, but the plugin interface is synchronous. Use `Task` and semaphores for blocking:

```swift
import Foundation

@_cdecl("aro_plugin_execute")
public func pluginExecute(
    _ actionPtr: UnsafePointer<CChar>,
    _ inputPtr: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
    let action = String(cString: actionPtr)
    let inputJSON = String(cString: inputPtr)

    guard let args = parseJSON(inputJSON) else {
        return strdup("{\"error\":\"Invalid JSON\"}")!
    }

    // Use a semaphore to bridge async completion into the synchronous C ABI
    let semaphore = DispatchSemaphore(value: 0)
    var asyncResult: [String: Any]?
    var asyncError: String?

    Task {
        do {
            switch action {
            case "fetch":
                asyncResult = try await fetchURL(args)
            default:
                asyncError = "Unknown action: \(action)"
            }
        } catch {
            asyncError = error.localizedDescription
        }
        semaphore.signal()
    }

    // Wait with timeout
    let timeout = DispatchTime.now() + .seconds(30)
    if semaphore.wait(timeout: timeout) == .timedOut {
        return strdup("{\"error\":\"Request timed out\"}")!
    }

    if let error = asyncError {
        let msg = error.replacingOccurrences(of: "\"", with: "\\\"")
        return strdup("{\"error\":\"\(msg)\"}")!
    }

    if let result = asyncResult,
       let data = try? JSONSerialization.data(withJSONObject: result),
       let json = String(data: data, encoding: .utf8) {
        return strdup(json)!
    }

    return strdup("{\"error\":\"No result\"}")!
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
// CORRECT: strdup creates a new allocation that ARO can free via aro_plugin_free
return strdup(jsonString)!

// WRONG: This pointer may be invalidated when the Swift string is deallocated
return jsonString.withCString { $0 }
```

ARO calls `aro_plugin_free` (which calls `free()`) on the returned pointer after reading it. Using `strdup` ensures the memory is heap-allocated in a way that `free()` can safely deallocate.

### Rule: Don't Hold References Across Calls

Each plugin call should be stateless:

```swift
// WRONG: Storing state between calls
private var sessionData: [String: Any] = [:]

@_cdecl("aro_plugin_execute")
public func pluginExecute(_ actionPtr: UnsafePointer<CChar>,
                          _ inputPtr: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
    // This will cause thread safety issues
    sessionData["key"] = value
    return strdup("{}")!
}

// CORRECT: Return all state in the response
@_cdecl("aro_plugin_execute")
public func pluginExecute(_ actionPtr: UnsafePointer<CChar>,
                          _ inputPtr: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
    // Include all necessary data in the result
    return strdup("{\"session_id\": \"...\", \"data\": []}")!
}
```

If you need persistent state, use thread-safe storage:

```swift
import Foundation

private let stateLock = NSLock()
private var globalState: [String: Any] = [:]

@_cdecl("aro_plugin_execute")
public func pluginExecute(_ actionPtr: UnsafePointer<CChar>,
                          _ inputPtr: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
    stateLock.lock()
    defer { stateLock.unlock() }

    // Safe to access globalState here
    return strdup("{\"ok\":true}")!
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
@_cdecl("aro_plugin_execute")
public func pluginExecute(
    _ actionPtr: UnsafePointer<CChar>,
    _ inputPtr: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
    guard let args = parseJSON(String(cString: inputPtr)) else {
        return strdup("{\"error\":\"Invalid JSON arguments\"}")!
    }

    // Validate required fields
    guard let requiredField = args["field"] as? String else {
        return strdup("{\"error\":\"Missing required field: 'field'\"}")!
    }

    guard !requiredField.isEmpty else {
        return strdup("{\"error\":\"Field 'field' cannot be empty\"}")!
    }

    // Now proceed with processing...
    return strdup("{\"ok\":true}")!
}
```

### Return Structured Errors

Include enough context for debugging:

```swift
private func pluginError(_ message: String, code: String? = nil) -> UnsafeMutablePointer<CChar> {
    var error: [String: Any] = ["error": message]
    if let code = code {
        error["code"] = code
    }

    guard let data = try? JSONSerialization.data(withJSONObject: error),
          let json = String(data: data, encoding: .utf8) else {
        return strdup("{\"error\":\"Unknown error\"}")!
    }

    return strdup(json)!
}

// Usage in aro_plugin_execute:
return pluginError("User not found", code: "USER_NOT_FOUND")
```

### Document Your Actions in aro_plugin_info

The `actions` and `services` arrays in `aro_plugin_info` help ARO discover what the plugin provides. Services are now declared here too—the old `aro_plugin_init` returning service metadata is removed:

```swift
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
                "prepositions": ["from", "with"],
                "description": "Format a date with locale support"
            }
        ],
        "services": [
            {
                "name": "datetime",
                "methods": ["format", "parse", "relative", "now", "add", "diff"],
                "description": "Date and time manipulation"
            }
        ]
    }
    """
    return strdup(metadata)!
}
```

Services route through `aro_plugin_execute` using the action name `"service:<method>"`. No separate `_call` symbol is needed.

## 6.10 Summary

Swift plugins combine the power of Apple's ecosystem with ARO's extensibility:

- **`@_cdecl`** exports functions with C calling conventions
- **`aro_plugin_info`** is **required**—declares all actions, services, and qualifiers
- **`aro_plugin_execute`** is **optional**—only needed for actions and services
- **`aro_plugin_init` / `aro_plugin_shutdown`** are optional `void` lifecycle hooks (the old init returning service metadata is removed)
- **`aro_plugin_execute`** uses a 2-parameter signature `(action, input) -> result`—no out-pointer or integer return code
- **Input JSON** nests `with { }` parameters under `"_with"`, and provides `result`, `source`, and `_context` descriptors
- **Single-file plugins** for simple cases, **package plugins** for dependencies
- **Foundation types** (DateFormatter, NumberFormatter, etc.) handle common formatting
- **SPM integration** enables using any Swift package
- **Memory**: Use `strdup` for return values, implement `aro_plugin_free`

The C ABI bridge adds a thin layer of complexity, but the payoff is access to Swift's entire ecosystem from your ARO applications.

Next, we'll explore Rust plugins—where performance meets safety.

