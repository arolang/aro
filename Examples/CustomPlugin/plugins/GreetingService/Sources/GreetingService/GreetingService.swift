// ============================================================
// GreetingService.swift
// Example ARO Plugin - Custom Greeting Service (using AROPluginKit)
// ============================================================
//
// Zero-boilerplate plugin using the AROPlugin builder.
//
// Usage in ARO:
//   <Call> the <result> from the <greeting: hello> with { name: "World" }.

import Foundation
import AROPluginKit

@AROExport
private let plugin = AROPlugin(name: "greeting-service", version: "1.0.0", handle: "Greeting")
    .service("greeting", methods: ["hello", "goodbye", "greet"]) { method, input in
        let name = input.with.string("name") ?? input.string("name") ?? "World"

        switch method.lowercased() {
        case "hello":
            return .success(["result": "Hello, \(name)!"])
        case "goodbye":
            return .success(["result": "Goodbye, \(name)! See you next time."])
        case "greet":
            let style = input.with.string("style") ?? input.string("style") ?? "formal"
            let greeting: String
            switch style {
            case "casual": greeting = "Hey \(name)! What's up?"
            case "enthusiastic": greeting = "WOW! Great to see you, \(name)!"
            default: greeting = "Good day, \(name). How may I assist you?"
            }
            return .success(["result": greeting])
        default:
            return .failure(.unsupported, "Unknown method: \(method)")
        }
    }


