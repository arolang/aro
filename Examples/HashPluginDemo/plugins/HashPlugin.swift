// ============================================================
// HashPlugin.swift
// ARO Plugin - Hash Functions Service
// ============================================================
//
// Provides various hash functions.
//
// Usage in ARO:
//   <Call> the <result> from the <hash-plugin: hash> with { data: "..." }.
//   <Call> the <result> from the <hash-plugin: djb2> with { data: "..." }.
//   <Call> the <result> from the <hash-plugin: fnv1a> with { data: "..." }.

import Foundation

// MARK: - Plugin Initialization

@_cdecl("aro_plugin_init")
public func pluginInit() -> UnsafePointer<CChar> {
    let metadata = """
    {"services": [{"name": "hash-plugin", "symbol": "hash_plugin_call", "methods": ["hash", "djb2", "fnv1a"]}]}
    """
    return UnsafePointer(strdup(metadata)!)
}

// MARK: - Service Implementation

@_cdecl("hash_plugin_call")
public func hashPluginCall(
    _ methodPtr: UnsafePointer<CChar>,
    _ argsPtr: UnsafePointer<CChar>,
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    let method = String(cString: methodPtr)
    let argsJSON = String(cString: argsPtr)

    // Parse arguments
    var args: [String: Any] = [:]
    if let data = argsJSON.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        args = parsed
    }

    guard let inputData = args["data"] as? String else {
        resultPtr.pointee = strdup("{\"error\": \"Missing 'data' field\"}")
        return 1
    }

    let result: [String: Any]

    switch method.lowercased() {
    case "hash", "simple":
        let hash = simpleHash(inputData)
        result = [
            "hash": String(format: "%08x", hash),
            "algorithm": "simple",
            "input": inputData
        ]

    case "djb2":
        let hash = djb2Hash(inputData)
        result = [
            "hash": String(format: "%016llx", hash),
            "algorithm": "djb2",
            "input": inputData
        ]

    case "fnv1a":
        let hash = fnv1aHash(inputData)
        result = [
            "hash": String(format: "%016llx", hash),
            "algorithm": "fnv1a",
            "input": inputData
        ]

    default:
        let errorJSON = "{\"error\": \"Unknown method: \(method)\"}"
        resultPtr.pointee = strdup(errorJSON)
        return 1
    }

    // Serialize result to JSON
    if let data = try? JSONSerialization.data(withJSONObject: result),
       let json = String(data: data, encoding: .utf8) {
        resultPtr.pointee = strdup(json)
        return 0
    }

    resultPtr.pointee = strdup("{\"error\": \"Failed to serialize result\"}")
    return 1
}

// MARK: - Hash Functions

/// Simple 32-bit hash
private func simpleHash(_ str: String) -> UInt32 {
    var hash: UInt32 = 0
    for char in str.utf8 {
        hash = hash &* 31 &+ UInt32(char)
    }
    return hash
}

/// DJB2 64-bit hash algorithm
private func djb2Hash(_ str: String) -> UInt64 {
    var hash: UInt64 = 5381
    for char in str.utf8 {
        hash = ((hash << 5) &+ hash) &+ UInt64(char)  // hash * 33 + c
    }
    return hash
}

/// FNV-1a 64-bit hash algorithm
private func fnv1aHash(_ str: String) -> UInt64 {
    var hash: UInt64 = 14695981039346656037
    let fnvPrime: UInt64 = 1099511628211
    for char in str.utf8 {
        hash ^= UInt64(char)
        hash = hash &* fnvPrime
    }
    return hash
}
