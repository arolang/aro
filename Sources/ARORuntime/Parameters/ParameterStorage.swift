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

    /// Positional arguments, in the order they appeared on the command line
    /// (ARO-0047 §Positional Arguments, GitLab #857).
    private var positionals: [String] = []

    /// Names the application's `Application-Start` header declared with
    /// `takes <a> <b>`, in order. A declared name resolves to the positional
    /// at the same index.
    ///
    /// Names and values are kept apart, and joined on read, so the order in
    /// which the two arrive does not matter: the interpreter declares names
    /// after parsing `argv`, the compiled binary declares them before, and
    /// both resolve the same.
    private var positionalNames: [String] = []

    /// Lock for thread-safe access
    private let lock = NSLock()

    /// Initialize a new ParameterStorage instance.
    /// Use `shared` for the singleton instance. Direct initialization is primarily for testing.
    public init() {}

    // MARK: - Public API

    /// Set a parameter value.
    public func set(_ key: String, value: any Sendable) {
        lock.lock()
        defer { lock.unlock() }
        parameters[key] = value
    }

    /// Get a parameter value by key.
    ///
    /// A flag wins over a declared positional of the same name: `--url X`
    /// is explicit, the position is inferred.
    public func get(_ key: String) -> (any Sendable)? {
        lock.lock()
        defer { lock.unlock() }
        if let flag = parameters[key] { return flag }
        if key == Self.argumentsKey { return positionals }
        guard let index = positionalNames.firstIndex(of: key),
              index < positionals.count else { return nil }
        return coerceType(positionals[index])
    }

    /// Positional arguments, in command-line order.
    public var arguments: [String] {
        lock.lock()
        defer { lock.unlock() }
        return positionals
    }

    /// Declare the positional names an `Application-Start` header asked for
    /// (`takes <url> <depth>`), in order.
    public func declarePositionals(_ names: [String]) {
        lock.lock()
        defer { lock.unlock() }
        positionalNames = names
    }

    /// The declared positional names, in order.
    public var declaredPositionals: [String] {
        lock.lock()
        defer { lock.unlock() }
        return positionalNames
    }

    /// The key under which the whole positional list is readable:
    /// `Extract the <args> from the <parameter: arguments>.`
    public static let argumentsKey = "arguments"

    /// Get all parameters as a dictionary.
    ///
    /// Declared positionals appear under their names, and the whole positional
    /// list under `arguments`, so `<parameter>` shows everything the program
    /// can reach through `<parameter: …>`.
    public func getAll() -> [String: any Sendable] {
        lock.lock()
        defer { lock.unlock() }
        var all: [String: any Sendable] = [Self.argumentsKey: positionals]
        for (index, name) in positionalNames.enumerated() where index < positionals.count {
            all[name] = coerceType(positionals[index])
        }
        // Flags last: an explicit --name wins over the positional of that name.
        for (key, value) in parameters { all[key] = value }
        return all
    }

    /// Clear all parameters.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        parameters.removeAll()
        positionals.removeAll()
        positionalNames.removeAll()
    }

    /// Check if a parameter exists.
    public func has(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if parameters[key] != nil { return true }
        if key == Self.argumentsKey { return true }
        guard let index = positionalNames.firstIndex(of: key) else { return false }
        return index < positionals.count
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
    /// - anything else → a positional argument, kept in order
    /// - `--` → end of flags; everything after it is positional
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
        var flagsEnded = false
        while i < args.count {
            let arg = args[i]

            if !flagsEnded && arg == "--" {
                // End of flags. Everything after is positional, including
                // things that look like options — which is how a positional
                // starting with `-` is passed at all.
                flagsEnded = true
            } else if flagsEnded {
                positionals.append(arg)
            } else if arg.hasPrefix("--") {
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
            } else {
                // A positional argument. `--key value` above still consumes
                // the token after it, so a boolean flag written bare in front
                // of a positional swallows it; `--flag=true`, or `--`, is how
                // the two are kept apart.
                positionals.append(arg)
            }

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
