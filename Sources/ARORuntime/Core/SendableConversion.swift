// ============================================================
// SendableConversion.swift
// ARORuntime - Shared JSON/Sendable Conversion Utility
// ============================================================
//
// Consolidates the 15+ duplicate convertToSendable / toJSON
// implementations into a single canonical utility.

import Foundation

#if canImport(Darwin)
import CoreFoundation
#endif

/// Centralised conversions between Foundation's `Any` (from JSONSerialization)
/// and Swift's `any Sendable` value graph.
public enum SendableConverter {

    // MARK: - Any → Sendable

    /// Recursively converts a JSON-deserialized `Any` value into a
    /// fully-typed `any Sendable` value graph.
    ///
    /// Handles: String, NSNumber (with Bool detection), Bool, Dict, Array,
    /// NSNull, and falls back to `String(describing:)`.
    public static func fromJSON(_ value: Any) -> any Sendable {
        switch value {
        case let str as String:
            return str
        // IMPORTANT: Check NSNumber BEFORE Bool.
        // On macOS, CFBoolean (used for JSON true/false) is a subclass of NSNumber
        // and can match both cases.
        case let nsNumber as NSNumber:
            let objCType = String(cString: nsNumber.objCType)
            #if canImport(Darwin)
            // On Darwin, CFBoolean has objCType "c" (signed char) and is for true/false.
            // Check CFBooleanGetTypeID to definitively identify JSON booleans.
            if CFGetTypeID(nsNumber) == CFBooleanGetTypeID() {
                return nsNumber.boolValue
            }
            #else
            // On Linux, JSONSerialization uses objCType "c" (signed char) for booleans.
            if objCType == "c" || objCType == "B" {
                let intVal = nsNumber.intValue
                if intVal == 0 || intVal == 1 {
                    return nsNumber.boolValue
                }
            }
            #endif
            // Check if it has a decimal point (is a double)
            if objCType == "d" || objCType == "f" {
                return nsNumber.doubleValue
            }
            // Check if it's an integer that fits in Int
            if floor(nsNumber.doubleValue) == nsNumber.doubleValue
                && abs(nsNumber.doubleValue) < Double(Int.max) {
                return nsNumber.intValue
            }
            return nsNumber.doubleValue
        case let bool as Bool:
            // This case should not be reached on macOS (CFBoolean is NSNumber)
            // but keep it for other platforms.
            return bool
        case let sendableDict as [String: any Sendable]:
            // Already the correct type — recurse to ensure nested values are clean
            var result: [String: any Sendable] = [:]
            for (k, v) in sendableDict {
                result[k] = fromJSON(v)
            }
            return result
        case let dict as [String: Any]:
            var result: [String: any Sendable] = [:]
            for (k, v) in dict {
                result[k] = fromJSON(v)
            }
            return result
        case let array as [Any]:
            return array.map { fromJSON($0) }
        case is NSNull:
            return "null"
        default:
            return String(describing: value)
        }
    }

    /// Convenience: converts a `[String: Any]` dictionary to `[String: any Sendable]`.
    public static func fromJSONDict(_ dict: [String: Any]) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        for (key, value) in dict {
            result[key] = fromJSON(value)
        }
        return result
    }

    // MARK: - Sendable → Any (for JSONSerialization)

    /// Converts a Sendable value graph to JSON-compatible `Any` suitable for
    /// `JSONSerialization.data(withJSONObject:)`.
    public static func toJSON(_ value: any Sendable) -> Any {
        switch value {
        case let str as String:
            return str
        case let int as Int:
            return int
        case let double as Double:
            return double
        case let bool as Bool:
            return bool
        case let dict as [String: any Sendable]:
            var result: [String: Any] = [:]
            for (k, v) in dict {
                result[k] = toJSON(v)
            }
            return result
        case let array as [any Sendable]:
            return array.map { toJSON($0) }
        case is NSNull:
            return NSNull()
        case let date as Date:
            let formatter = ISO8601DateFormatter()
            return formatter.string(from: date)
        case let data as Data:
            return data.base64EncodedString()
        default:
            return String(describing: value)
        }
    }

    // MARK: - Convenience

    /// Serializes a Sendable value to JSON `Data`.
    public static func toJSONData(_ value: any Sendable, prettyPrint: Bool = false) throws -> Data {
        let jsonObject = toJSON(value)
        let options: JSONSerialization.WritingOptions = prettyPrint ? [.prettyPrinted] : []
        return try JSONSerialization.data(withJSONObject: jsonObject, options: options)
    }
}
