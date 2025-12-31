// ============================================================
// ConsoleObject.swift
// ARO Runtime - Console System Object
// ============================================================

import Foundation

// MARK: - Console Object

/// Console system object for standard output
///
/// The console is a sink-only object that writes to stdout.
///
/// ## ARO Usage
/// ```aro
/// <Log> "Hello, World!" to the <console>.
/// <Log> <message> to the <console>.
/// ```
public struct ConsoleObject: SystemObject, Instantiable {
    public static let identifier = "console"
    public static let description = "Standard output stream"

    public var capabilities: SystemObjectCapabilities { .sink }

    public init() {}

    public func write(_ value: any Sendable) async throws {
        let message = formatValue(value)
        print(message)
    }

    public func read(property: String?) async throws -> any Sendable {
        throw SystemObjectError.notReadable(Self.identifier)
    }

    private func formatValue(_ value: any Sendable) -> String {
        return ResponseFormatter.formatValue(value, for: .developer)
    }
}

// MARK: - Stderr Object

/// Standard error stream system object
///
/// Similar to console but writes to stderr.
///
/// ## ARO Usage
/// ```aro
/// <Log> <error-message> to the <stderr>.
/// ```
public struct StderrObject: SystemObject, Instantiable {
    public static let identifier = "stderr"
    public static let description = "Standard error stream"

    public var capabilities: SystemObjectCapabilities { .sink }

    public init() {}

    public func write(_ value: any Sendable) async throws {
        let message = formatValue(value)
        // Use FileHandle for concurrency safety
        if let data = (message + "\n").data(using: .utf8) {
            try FileHandle.standardError.write(contentsOf: data)
        }
    }

    public func read(property: String?) async throws -> any Sendable {
        throw SystemObjectError.notReadable(Self.identifier)
    }

    private func formatValue(_ value: any Sendable) -> String {
        return ResponseFormatter.formatValue(value, for: .developer)
    }
}

// MARK: - Stdin Object

/// Standard input stream system object
///
/// A source-only object for reading from stdin.
///
/// ## ARO Usage
/// ```aro
/// <Read> the <input> from the <stdin>.
/// <Read> the <line> from the <stdin: line>.
/// ```
public struct StdinObject: SystemObject, Instantiable {
    public static let identifier = "stdin"
    public static let description = "Standard input stream"

    public var capabilities: SystemObjectCapabilities { .source }

    public init() {}

    public func read(property: String?) async throws -> any Sendable {
        switch property {
        case "line", nil:
            // Read a single line
            guard let line = readLine() else {
                return ""
            }
            return line
        case "all":
            // Read all available input
            var lines: [String] = []
            while let line = readLine() {
                lines.append(line)
            }
            return lines.joined(separator: "\n")
        default:
            throw SystemObjectError.propertyNotFound(property!, in: Self.identifier)
        }
    }

    public func write(_ value: any Sendable) async throws {
        throw SystemObjectError.notWritable(Self.identifier)
    }
}

// MARK: - Registration

public extension SystemObjectRegistry {
    /// Register console-related system objects
    func registerConsoleObjects() {
        register(ConsoleObject.self)
        register(StderrObject.self)
        register(StdinObject.self)
    }
}
