// ============================================================
// CounterService.swift
// Example ARO Plugin - Stateful Counter Service (using AROPluginKit)
// ============================================================
//
// Zero-boilerplate plugin using the AROPlugin builder.
// No @_cdecl, no JSON, no manual memory management.
//
// Usage in ARO:
//   <Call> the <result> from the <counter: increment> with {}.
//   <Call> the <result> from the <counter: get> with {}.
//   <Call> the <result> from the <counter: reset> with {}.

import Foundation
import AROPluginKit

// MARK: - State Management

/// Global counter state (persists for application lifetime)
private var globalCount: Int = 0
private let counterQueue = DispatchQueue(label: "counter.service")

// MARK: - Plugin Registration

private let plugin = AROPlugin(name: "counter-plugin", version: "1.0.0", handle: "Counter")
    .service("counter", methods: ["increment", "get", "reset"]) { method, input in
        let result: [String: Any] = counterQueue.sync {
            switch method.lowercased() {
            case "increment":
                globalCount += 1
                return ["count": globalCount, "message": "Incremented"]
            case "get":
                return ["count": globalCount]
            case "reset":
                globalCount = 0
                return ["count": 0, "message": "Reset"]
            default:
                return ["error": "Unknown method: \(method)"]
            }
        }
        return .success(result)
    }
    .onInit {
        counterQueue.sync { globalCount = 0 }
    }

@_cdecl("aro_plugin_register")
public func registerPlugin() { _ = plugin }
