# Chapter 16: Plugins

*"Share your actions with the world."*

---

## 16.1 What Are Plugins?

Plugins are Swift packages that provide custom actions for ARO applications. They allow you to package related actions together, share them across projects, and distribute them to other developers through Swift Package Manager.

The plugin system exists because real applications often need specialized capabilities that the built-in actions do not provide. Database drivers, payment processors, notification services, analytics platforms, and countless other integrations require custom code. Plugins provide a structured way to create, distribute, and use these extensions.

A plugin is fundamentally a Swift package that follows certain conventions. It depends on the ARO runtime, implements one or more actions, and provides a registration function that the runtime calls at startup. Users of the plugin add it as a dependency and immediately gain access to its actions.

The benefits of the plugin approach include reusability across projects, independent versioning and maintenance, clear boundaries between core ARO functionality and extensions, and the ability to share useful integrations with the community.

---

## 16.2 Plugin Structure

A plugin follows standard Swift package conventions with a few ARO-specific requirements. The package contains source files implementing actions, a registration function that the runtime calls, and optionally tests and documentation.

The package manifest declares the plugin as a dynamic library product. This is important for runtime loading scenarios where the plugin is discovered and loaded as a shared library rather than statically linked during compilation.

The source files contain action implementations following the ActionImplementation protocol described in the previous chapter. Each action has its role, verbs, valid prepositions, and execute method. The actions can depend on external libraries for integrating with services.

The registration function has a specific name that the runtime looks for: aro_plugin_register. When the plugin loads, the runtime calls this function, which registers all the plugin's actions with the action registry. After registration, the actions are available for use in ARO code.

---

## 16.3 Creating a Plugin

Creating a plugin begins with setting up a Swift package. The package manifest specifies the ARO runtime as a dependency and configures the library product as dynamic. Any additional dependencies your actions need are also specified here.

The entry point file contains the registration function marked with the @_cdecl attribute. This attribute ensures the function is callable from C code, which is how the runtime discovers and calls it. Inside this function, you register each action type with the shared action registry.

Action implementations follow the same patterns described for custom actions. Each action is a struct conforming to ActionImplementation with the required static properties and execute method. You can organize related actions into separate files and use supporting types and services as needed.

Testing follows standard Swift testing practices. You create test targets that depend on your plugin and test the action implementations. Because actions have a well-defined interface, they are straightforward to test with mock contexts and assertions on outputs.

### Complete Example: ZipPlugin

Here is a complete plugin that provides file compression using an external library. This example demonstrates the full plugin structure including Package.swift, the service implementation, and usage from ARO.

**Directory Structure:**

```
ZipService/
├── main.aro                              # ARO application using the plugin
├── content/                              # Files to compress
│   ├── file1.txt
│   └── file2.txt
└── plugins/
    └── ZipPlugin/
        ├── Package.swift                 # Plugin manifest
        └── Sources/ZipPlugin/
            └── ZipService.swift          # Plugin implementation
```

**Package.swift** — Plugin manifest with external dependency:

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

**ZipService.swift** — Plugin implementation with three methods:

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

    // Parse arguments and execute method
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

**main.aro** — Using the plugin in an ARO application:

```aro
(* ZipService - Demonstrates using a plugin with external dependencies *)

(Application-Start: Zip Service Demo) {
    <Log> the <message> for the <console> with "Testing zip plugin...".

    (* Compress files into a zip archive *)
    <Call> the <result> from the <zip: compress> with {
        files: ["content/file1.txt", "content/file2.txt"],
        output: "content/archive.zip"
    }.

    <Log> the <message> for the <console> with "Zip result:".
    <Log> the <message> for the <console> with <result>.

    <Return> an <OK: status> for the <startup>.
}
```

> **Source:** See `Examples/ZipService` in the ARO repository for the complete working example.

---

## 16.4 Using Plugins

Using a plugin in your application involves adding it as a dependency and optionally loading it at runtime. The simplest approach is compile-time linking where the plugin is a package dependency.

In your application's Package.swift, you add the plugin package as a dependency and include it in your target's dependencies. When you build and run your application, the plugin's registration function is called during initialization, making its actions available.

For runtime loading, you place compiled plugin libraries in a plugins directory within your application. During Application-Start, you execute a Load action that scans this directory and loads any plugins found. This approach allows adding plugins without recompiling the application.

Once a plugin is loaded, its actions are indistinguishable from built-in actions. You use them with the same statement syntax, the same prepositions, the same patterns. The plugin nature is transparent to ARO code.

---

## 16.5 Plugin Design

Good plugin design follows several principles that make plugins useful and maintainable.

Cohesion means grouping related actions together. A database plugin provides connect, query, insert, update, and delete actions for that database. A payment plugin provides charge, refund, and status actions. Each plugin has a focused purpose.

Naming should be distinctive to avoid conflicts. If your plugin provides a Query action and another plugin also provides Query, there is a conflict. Prefixing verbs with your domain—QueryDB, QueryMongo, QueryRedis—avoids this problem while remaining readable.

Configuration should be explicit. If your actions need configuration like connection strings or API keys, provide clear patterns for supplying them. Common approaches include configuration actions that run during startup or reading from environment variables.

Error handling should produce clear messages. When your plugin's actions fail, users see the error messages you provide. Include relevant context—which resource could not be found, why the connection failed, what validation rule was violated.

---

## 16.6 Documentation

Plugin documentation is essential for users to effectively use your actions. Without documentation, users must read source code to understand what actions are available and how to use them.

Document each action with its purpose, valid prepositions, expected inputs, outputs, and possible errors. Include example ARO statements showing typical usage. Explain any configuration requirements or prerequisites.

A README file should provide installation instructions, a quick start example, and references to detailed documentation. Users should be able to get started quickly and find comprehensive information when they need it.

Consider including an example application that demonstrates your plugin in context. Seeing actions used in a complete application helps users understand how to integrate the plugin into their own projects.

---

## 16.7 Publishing

Publishing a plugin makes it available to other developers. Swift Package Manager works with Git repositories, so publishing means tagging releases in a repository.

Create a Git repository for your plugin, push your code, and create tags for releases. Follow semantic versioning: major versions for breaking changes, minor versions for new features, patch versions for bug fixes. Users depend on version ranges, so breaking changes in minor versions cause problems.

Consider publishing to GitHub where the Swift community can discover your plugin. Include clear documentation, a permissive license for broad adoption, and issue tracking for bug reports and feature requests.

Announce your plugin in relevant communities—forums, social media, newsletters—so developers who might benefit learn about it.

---

## 16.8 Best Practices

Choose verb names that read naturally and avoid conflicts. Prefixing with your domain is safer than using generic names. "Geocode" might conflict with another plugin; "MapboxGeocode" is distinctive.

Provide comprehensive error messages. Users of your plugin will debug issues using the messages you provide. Clear, specific messages save everyone time.

Test thoroughly. Your actions may be used in ways you did not anticipate. Test edge cases, error conditions, and unusual inputs. Automated tests help maintain quality as you evolve the plugin.

Version carefully. Breaking changes require major version bumps. Document changes in release notes so users know what to expect when upgrading.

Keep dependencies minimal. Each dependency you add is a dependency your users must accept. Heavy dependencies increase build times, binary sizes, and potential for conflicts.

---

*Next: Chapter 17 — Native Compilation*
