// ParameterStorage.swift
// ARO-0047: Command-Line Parameters
//
// Thread-safe storage for command-line parameters parsed from argc/argv.

import Foundation

/// Thread-safe singleton storage for command-line parameters.
///
/// Parameters are parsed from command-line arguments and made available
/// to ARO code via the `parameter` system object:
///
/// ```aro
/// <Extract> the <url> from the <parameter: url>.
/// ```
public final class ParameterStorage: @unchecked Sendable {

    /// Shared singleton instance
    public static let shared = ParameterStorage()

    /// Stored parameters with automatic type coercion
    private var parameters: [String: any Sendable] = [:]

    /// Lock for thread-safe access
    private let lock = NSLock()

    private init() {}

    // MARK: - Public API

    /// Set a parameter value.
    public func set(_ key: String, value: any Sendable) {
        lock.lock()
        defer { lock.unlock() }
        parameters[key] = value
    }

    /// Get a parameter value by key.
    public func get(_ key: String) -> (any Sendable)? {
        lock.lock()
        defer { lock.unlock() }
        return parameters[key]
    }

    /// Get all parameters as a dictionary.
    public func getAll() -> [String: any Sendable] {
        lock.lock()
        defer { lock.unlock() }
        return parameters
    }

    /// Clear all parameters.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        parameters.removeAll()
    }

    /// Check if a parameter exists.
    public func has(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return parameters[key] != nil
    }

    // MARK: - Argument Parsing

    /// Parse command-line arguments into parameters.
    ///
    /// Supports the following patterns:
    /// - `--key value` → Named parameter with value
    /// - `--key=value` → Named parameter with equals syntax
    /// - `--flag` → Boolean flag (true)
    /// - `-f` → Short boolean flag (true)
    /// - `-abc` → Combined short flags (each true)
    ///
    /// Values are automatically type-coerced:
    /// - Integer pattern → Int
    /// - Float pattern → Double
    /// - "true"/"false" → Bool
    /// - Otherwise → String
    public func parseArguments(_ args: [String]) {
        lock.lock()
        defer { lock.unlock() }

        var i = 0
        while i < args.count {
            let arg = args[i]

            if arg.hasPrefix("--") {
                // Long option
                let optionPart = String(arg.dropFirst(2))

                if let equalsIndex = optionPart.firstIndex(of: "=") {
                    // --key=value
                    let key = String(optionPart[..<equalsIndex])
                    let value = String(optionPart[optionPart.index(after: equalsIndex)...])
                    parameters[key] = coerceType(value)
                } else if i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                    // --key value
                    let key = optionPart
                    let value = args[i + 1]
                    parameters[key] = coerceType(value)
                    i += 1
                } else {
                    // --flag (boolean)
                    parameters[optionPart] = true
                }
            } else if arg.hasPrefix("-") && arg.count > 1 {
                // Short option(s)
                let flags = String(arg.dropFirst())

                // Each character is a boolean flag
                for char in flags {
                    parameters[String(char)] = true
                }
            }
            // Skip positional arguments (not starting with -)

            i += 1
        }
    }

    // MARK: - Type Coercion

    /// Coerce a string value to the appropriate type.
    ///
    /// - Integer pattern (`^\d+$`) → Int
    /// - Float pattern (`^\d+\.\d+$`) → Double
    /// - "true"/"false" → Bool
    /// - Otherwise → String
    private func coerceType(_ value: String) -> any Sendable {
        // Check for boolean
        if value.lowercased() == "true" {
            return true
        }
        if value.lowercased() == "false" {
            return false
        }

        // Check for integer
        if let intValue = Int(value), String(intValue) == value {
            return intValue
        }

        // Check for double
        if let doubleValue = Double(value), value.contains(".") {
            return doubleValue
        }

        // Default to string
        return value
    }
}
