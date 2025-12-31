# Chapter 21: Plugins

*"Package and share your extensions."*

---

## 21.1 What Are Plugins?

Plugins are Swift packages that provide custom actions and services for ARO applications. They allow you to package extensions together, share them across projects, and distribute them to other developers through Swift Package Manager.

The plugin system exists because real applications often need specialized capabilities that the built-in features do not provide. Plugins provide a structured way to create, distribute, and use these extensions.

A plugin can contain two types of extensions:

| Type | Adds | Invocation Pattern | Example |
|------|------|-------------------|---------|
| **Actions** | New verbs | `<Verb> the <result> from <object>.` | `<Geocode> the <coords> from <address>.` |
| **Services** | External integrations | `<Call> from <service: method>` | `<Call> from <zip: compress>` |

The distinction matters for plugin design. Actions extend the language vocabulary—each action adds a new verb. Services extend runtime capabilities—they share the `Call` verb but provide different methods.

---

## 21.2 Plugin Structure

A plugin follows standard Swift package conventions with ARO-specific requirements. The package contains source files, a registration function, and optionally tests and documentation.

The package manifest declares the plugin as a dynamic library product. This enables runtime loading where the plugin is discovered and loaded as a shared library.

**For Action Plugins:**
- Implement the `ActionImplementation` protocol
- Registration function calls `ActionRegistry.shared.register(YourAction.self)`
- Each action adds a new verb to ARO

**For Service Plugins:**
- Use the C-callable interface with `aro_plugin_init`
- Return JSON metadata describing services and their symbols
- Each service is called via `<Call> from <service: method>`

---

## 21.3 Creating an Action Plugin

Action plugins add new verbs to ARO. Here is a complete example of a Geocoding action plugin.

**Directory Structure:**

```
GeocodePlugin/
├── Package.swift
├── Sources/GeocodePlugin/
│   ├── GeocodeAction.swift
│   └── Registration.swift
└── Tests/GeocodePluginTests/
    └── GeocodeActionTests.swift
```

**Package.swift:**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GeocodePlugin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GeocodePlugin", type: .dynamic, targets: ["GeocodePlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/your-org/ARORuntime.git", from: "1.0.0")
    ],
    targets: [
        .target(name: "GeocodePlugin", dependencies: ["ARORuntime"])
    ]
)
```

**GeocodeAction.swift:**

```swift
import ARORuntime

public struct GeocodeAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["Geocode"]
    public static let validPrepositions: Set<Preposition> = [.from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Get the address from context
        let address: String = try context.require(object.identifier)

        // Call geocoding API (simplified)
        let coordinates = try await geocode(address)

        // Bind result
        context.bind(result.identifier, value: coordinates)

        return coordinates
    }

    private func geocode(_ address: String) async throws -> [String: Double] {
        // Implementation using a geocoding service
        // Returns ["latitude": 37.7749, "longitude": -122.4194]
    }
}
```

**Registration.swift:**

```swift
import ARORuntime

@_cdecl("aro_plugin_register")
public func registerPlugin() {
    ActionRegistry.shared.register(GeocodeAction.self)
}
```

**Usage in ARO:**

```aro
(Get Location: Address Lookup) {
    <Create> the <address> with "1600 Amphitheatre Parkway, Mountain View, CA".

    (* Custom action - new verb *)
    <Geocode> the <coordinates> from the <address>.

    <Log> <coordinates> to the <console>.
    <Return> an <OK: status> with <coordinates>.
}
```

---

## 21.4 Creating a Service Plugin

Service plugins provide external integrations called via the `Call` action. Here is a complete example of a Zip service plugin.

**Directory Structure:**

```
ZipPlugin/
├── Package.swift
└── Sources/ZipPlugin/
    └── ZipService.swift
```

**Package.swift:**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZipPlugin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ZipPlugin", type: .dynamic, targets: ["ZipPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/marmelroy/Zip.git", from: "2.1.0")
    ],
    targets: [
        .target(name: "ZipPlugin", dependencies: ["Zip"])
    ]
)
```

**ZipService.swift:**

```swift
import Foundation
import Zip

// Plugin initialization - returns service metadata as JSON
@_cdecl("aro_plugin_init")
public func pluginInit() -> UnsafePointer<CChar> {
    let metadata = """
    {"services": [{"name": "zip", "symbol": "zip_call"}]}
    """
    return UnsafePointer(strdup(metadata)!)
}

// Main entry point for the zip service
@_cdecl("zip_call")
public func zipCall(
    _ methodPtr: UnsafePointer<CChar>,
    _ argsPtr: UnsafePointer<CChar>,
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    let method = String(cString: methodPtr)
    let argsJSON = String(cString: argsPtr)

    do {
        let args = try parseJSON(argsJSON)
        let result = try executeMethod(method, args: args)
        resultPtr.pointee = encodeJSON(result).withCString { strdup($0) }
        return 0
    } catch {
        resultPtr.pointee = "{\"error\": \"\(error)\"}".withCString { strdup($0) }
        return 1
    }
}

private func executeMethod(_ method: String, args: [String: Any]) throws -> [String: Any] {
    switch method.lowercased() {
    case "compress", "zip":
        guard let files = args["files"] as? [String],
              let output = args["output"] as? String else {
            throw PluginError.missingArgument
        }
        let fileURLs = files.map { URL(fileURLWithPath: $0) }
        try Zip.zipFiles(paths: fileURLs, zipFilePath: URL(fileURLWithPath: output), password: nil, progress: nil)
        return ["success": true, "output": output, "filesCompressed": files.count]

    case "decompress", "unzip":
        guard let archive = args["archive"] as? String else {
            throw PluginError.missingArgument
        }
        let destination = args["destination"] as? String ?? "."
        try Zip.unzipFile(URL(fileURLWithPath: archive), destination: URL(fileURLWithPath: destination), overwrite: true, password: nil)
        return ["success": true, "destination": destination]

    default:
        throw PluginError.unknownMethod(method)
    }
}

enum PluginError: Error {
    case missingArgument, unknownMethod(String)
}
```

**Usage in ARO:**

```aro
(Compress Files: Archive) {
    (* Service call - uses Call action *)
    <Call> the <result> from the <zip: compress> with {
        files: ["file1.txt", "file2.txt"],
        output: "archive.zip"
    }.

    <Log> <result> to the <console>.
    <Return> an <OK: status> for the <compression>.
}
```

---

## 21.5 Choosing Between Action and Service Plugins

When designing a plugin, consider which approach fits better:

### Choose Action Plugin When:

- The operation feels like a language feature
- You want natural syntax: `<Geocode>`, `<Encrypt>`, `<Validate>`
- The operation is single-purpose
- Readability is paramount

```aro
(* Natural, domain-specific syntax *)
<Geocode> the <coordinates> from the <address>.
<Encrypt> the <ciphertext> from the <plaintext> with <key>.
<Validate> the <result> for the <order>.
```

### Choose Service Plugin When:

- You are wrapping an external system with multiple operations
- You want a uniform interface: `<Call> from <service: method>`
- The integration has many related methods
- Portability across projects matters

```aro
(* Uniform service pattern *)
<Call> the <result> from the <postgres: query> with { sql: "..." }.
<Call> the <result> from the <postgres: insert> with { table: "...", data: ... }.
<Call> the <result> from the <zip: compress> with { files: [...] }.
<Call> the <result> from the <zip: decompress> with { archive: "..." }.
```

### Comparison Table

| Aspect | Action Plugin | Service Plugin |
|--------|---------------|----------------|
| Syntax | `<Verb> the <result>...` | `<Call> from <service: method>` |
| Protocol | `ActionImplementation` | C-callable with JSON |
| Methods | One per action | Multiple per service |
| Registration | `ActionRegistry.register()` | `aro_plugin_init` JSON |
| Best for | Domain operations | External integrations |

---

## 21.6 Plugin Loading

Plugins load in two ways: compile-time linking and runtime discovery.

**Compile-time linking** adds the plugin as a package dependency. When you build your application, the plugin is linked in. The registration function runs during initialization.

**Runtime discovery** scans a `plugins/` directory for compiled libraries. During startup, ARO loads each library and calls its registration function. This allows adding plugins without recompiling.

For runtime loading, place compiled `.dylib` (macOS), `.so` (Linux), or `.dll` (Windows) files in `./plugins/`. ARO loads them automatically during Application-Start.

---

## 21.7 Plugin Design Guidelines

**Cohesion**: Group related functionality. A database plugin provides all database operations. A compression plugin provides all compression methods.

**Naming**: Use distinctive names. For actions, prefix with your domain if conflicts are possible. For services, choose clear names that describe the integration.

**Configuration**: Use environment variables for credentials and connection strings. This keeps configuration separate from code and allows different values per environment.

**Error messages**: Provide clear, actionable errors. Include what failed, why, and ideally what to do about it.

---

## 21.8 Documentation

Document your plugin thoroughly:

- **Actions**: List verbs, valid prepositions, expected inputs, outputs, errors
- **Services**: List methods, arguments for each, return values
- **Configuration**: Environment variables, required setup
- **Examples**: Show typical usage in ARO code

A README should provide quick start instructions. Users should be productive within minutes of adding your plugin.

---

## 21.9 Publishing

Publish plugins through Git repositories. Swift Package Manager resolves dependencies from URLs.

1. Create a Git repository for your plugin
2. Tag releases following semantic versioning
3. Document installation in your README
4. Announce in relevant communities

Example installation instruction:

```swift
// In your Package.swift
dependencies: [
    .package(url: "https://github.com/your-org/GeocodePlugin.git", from: "1.0.0")
]
```

---

## 21.10 Best Practices

**Test thoroughly.** Plugins may be used in unexpected ways. Test edge cases and error conditions.

**Version carefully.** Breaking changes require major version bumps. Users depend on stability.

**Keep dependencies minimal.** Each dependency is a dependency for your users. Heavy dependencies cause conflicts.

**Document everything.** Users should not need to read source code to use your plugin.

---

*Next: Chapter 22 — Native Compilation*
