// ============================================================
// CollectionPlugin.swift
// ARO Plugin - Swift Qualifier Example (using AROPluginSDK)
// ============================================================
//
// This plugin demonstrates the zero-boilerplate SDK pattern.
// No @_cdecl, no JSON, no manual memory management.
// The SDK auto-generates all C ABI exports.

import Foundation
import AROPluginSDK

/// Plugin registration — this is the ONLY setup needed.
/// The SDK generates aro_plugin_info, aro_plugin_qualifier,
/// aro_plugin_free, aro_plugin_init, and aro_plugin_shutdown.
private let plugin = AROPlugin(name: "plugin-swift-collection", version: "1.0.0", handle: "Collections")
    .qualifier("pick-random", inputTypes: ["List"], description: "Pick a random element from a list") { params in
        guard let array = params.arrayValue, !array.isEmpty else {
            return .failure("pick-random requires a non-empty list")
        }
        let randomIndex = Int.random(in: 0..<array.count)
        return .success(array[randomIndex])
    }
    .qualifier("shuffle", inputTypes: ["List", "String"], description: "Shuffle elements or characters") { params in
        if let array = params.arrayValue {
            return .success(array.shuffled())
        }
        if let string = params.stringValue {
            return .success(String(string.shuffled()))
        }
        return .failure("shuffle requires a list or string")
    }
    .qualifier("reverse", inputTypes: ["List", "String"], description: "Reverse elements or characters") { params in
        if let array = params.arrayValue {
            return .success(Array(array.reversed()))
        }
        if let string = params.stringValue {
            return .success(String(string.reversed()))
        }
        return .failure("reverse requires a list or string")
    }

// Register with the SDK — this wires up all C ABI exports automatically
@_cdecl("_aro_plugin_register")
public func register() {
    AROPluginExport.register(plugin)
}

// Static initializer to ensure registration happens at load time
private let _: Void = {
    AROPluginExport.register(plugin)
}()
