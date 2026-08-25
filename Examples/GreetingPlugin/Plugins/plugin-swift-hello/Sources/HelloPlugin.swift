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

/// The plugin's own name, reported back in every action result so a
/// caller can tell which plugin answered.
private let pluginName = "plugin-swift-hello"

/// Both actions return their text under `message`.
///
/// This is the plugin's published contract: the README documents
/// `message` / `timestamp` / `plugin`, and `main.aro` reads
/// `<greeting: message>`. An earlier rewrite onto the SDK changed the
/// key to `greeting` / `farewell`, which broke every caller — the
/// example printed two blank lines and two extraction errors, and had
/// done so for several releases because `expected.txt` only asserted
/// the banner line printed before the plugin is ever called.
///
/// Keying the result on the *action* also makes the output shape vary
/// per action, so no caller can read a greeting and a farewell the
/// same way. `message` is the same field whichever action produced it.
private func greetingResult(_ text: String) -> [String: Any] {
    [
        "message": text,
        "timestamp": ISO8601DateFormatter().string(from: Date()),
        "plugin": pluginName,
    ]
}

/// Plugin registration — this is the ONLY setup needed.
@AROExport
private let plugin = AROPlugin(name: pluginName, version: "1.0.0", handle: "Greeting")
    .action("Greet", verbs: ["greet"], role: "own", prepositions: ["with"],
            description: "Generate a greeting message") { input in
        let name = input.string("name")
            ?? input.string("data")
            ?? input.with.string("name")
            ?? "World"
        return .success(greetingResult("Hello, \(name)!"))
    }
    .action("Farewell", verbs: ["farewell"], role: "own", prepositions: ["with"],
            description: "Generate a farewell message") { input in
        let name = input.string("name")
            ?? input.string("data")
            ?? input.with.string("name")
            ?? "World"
        return .success(greetingResult("Goodbye, \(name)!"))
    }

