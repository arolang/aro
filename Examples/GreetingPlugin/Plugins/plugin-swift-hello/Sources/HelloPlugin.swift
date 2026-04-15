// ============================================================
// HelloPlugin.swift
// ARO Plugin - Swift Action Example (using AROPluginSDK)
// ============================================================
//
// This plugin demonstrates the zero-boilerplate SDK pattern.
// No @_cdecl, no JSON, no manual memory management.
// The SDK auto-generates all C ABI exports.

import Foundation
import AROPluginKit

/// Plugin registration — this is the ONLY setup needed.
private let plugin = AROPlugin(name: "plugin-swift-hello", version: "1.0.0", handle: "Greeting")
    .action("Greet", verbs: ["greet"], role: "own", prepositions: ["with"],
            description: "Generate a greeting message") { input in
        let name = input.string("name")
            ?? input.string("data")
            ?? input.with.string("name")
            ?? "World"
        return .success(["greeting": "Hello, \(name)!"])
    }
    .action("Farewell", verbs: ["farewell"], role: "own", prepositions: ["with"],
            description: "Generate a farewell message") { input in
        let name = input.string("name")
            ?? input.string("data")
            ?? input.with.string("name")
            ?? "World"
        return .success(["farewell": "Goodbye, \(name)!"])
    }

// Explicit registration entry point — called by the ARO runtime before
// aro_plugin_info.  On Linux, lazy static initializers may not run before
// the first function call into the .so, and the SDK's fallback dlsym lookup
// crashes the dynamic linker (TLS exhaustion).  This @_cdecl ensures safe init.
@_cdecl("aro_plugin_register")
public func registerPlugin() {
    AROPluginExport.register(plugin)
}
