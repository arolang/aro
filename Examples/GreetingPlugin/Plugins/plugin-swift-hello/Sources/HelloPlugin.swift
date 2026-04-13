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

// Static initializer — registers the plugin at dylib load time
private let _registration: Void = {
    AROPluginExport.register(plugin)
}()
