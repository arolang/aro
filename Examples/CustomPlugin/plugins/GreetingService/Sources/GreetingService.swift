// ============================================================
// GreetingService.swift
// Example ARO Plugin - Custom Greeting Service (using AROPluginKit)
// ============================================================
//
// Zero-boilerplate plugin using the AROPlugin builder.
//
// Usage in ARO:
//   Greeting.Hello the <msg> with { name: "World" }.
//   Greeting.Goodbye the <msg> with { name: "World" }.

import Foundation
import AROPluginKit

@AROExport
private let plugin = AROPlugin(name: "greeting-service", version: "1.0.0", handle: "Greeting")
    .action("Hello", verbs: ["hello"], role: "own", prepositions: ["with"],
            description: "Generate a hello greeting") { input in
        let name = input.with.string("name") ?? input.string("name") ?? "World"
        return .success(["result": "Hello, \(name)!"])
    }
    .action("Goodbye", verbs: ["goodbye"], role: "own", prepositions: ["with"],
            description: "Generate a goodbye message") { input in
        let name = input.with.string("name") ?? input.string("name") ?? "World"
        return .success(["result": "Goodbye, \(name)! See you next time."])
    }
    .action("Greet", verbs: ["greet"], role: "own", prepositions: ["with"],
            description: "Generate a styled greeting") { input in
        let name = input.with.string("name") ?? input.string("name") ?? "World"
        let style = input.with.string("style") ?? input.string("style") ?? "formal"
        let greeting: String
        switch style {
        case "casual": greeting = "Hey \(name)! What's up?"
        case "enthusiastic": greeting = "WOW! Great to see you, \(name)!"
        default: greeting = "Good day, \(name). How may I assist you?"
        }
        return .success(["result": greeting])
    }
