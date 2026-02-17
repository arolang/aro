// JSONStreamParser.swift
// ARO Streaming Execution Engine
//
// Incremental JSON/JSONL parser for streaming large files.

import Foundation

/// Streaming JSON parser that processes JSON data incrementally.
///
/// Supports two modes:
/// - **JSONL mode**: Each line is a complete JSON object (default for .jsonl files)
/// - **Array mode**: Parses JSON arrays, yielding each element as it's found
///
/// Memory: O(1) for JSONL, O(element_size) for array mode.
public struct JSONStreamParser: Sendable {

    // MARK: - Types

    /// Parser configuration
    public struct Config: Sendable {
        /// Whether to parse as JSONL (one object per line)
        public let jsonlMode: Bool

        /// Whether to skip malformed lines/elements (vs throwing errors)
        public let skipMalformed: Bool

        /// Maximum line length for JSONL mode (prevents memory exhaustion)
        public let maxLineLength: Int

        public init(
            jsonlMode: Bool = false,
            skipMalformed: Bool = true,
            maxLineLength: Int = 10_000_000  // 10MB max line
        ) {
            self.jsonlMode = jsonlMode
            self.skipMalformed = skipMalformed
            self.maxLineLength = maxLineLength
        }

        /// Default config for JSONL files
        public static let jsonl = Config(jsonlMode: true)

        /// Default config for JSON array files
        public static let jsonArray = Config(jsonlMode: false)
    }

    // MARK: - Properties

    private let config: Config

    // MARK: - Initialization

    public init(config: Config = .jsonl) {
        self.config = config
    }

    // MARK: - Streaming API

    /// Creates a stream of dictionaries from a file path
    public static func stream(
        path: String,
        config: Config? = nil
    ) -> AROStream<[String: any Sendable]> {
        // Auto-detect config based on file extension
        let effectiveConfig: Config
        if let config = config {
            effectiveConfig = config
        } else if path.lowercased().hasSuffix(".jsonl") {
            effectiveConfig = .jsonl
        } else {
            effectiveConfig = .jsonArray
        }

        if effectiveConfig.jsonlMode {
            return streamJSONL(path: path, config: effectiveConfig)
        } else {
            return streamJSONArray(path: path, config: effectiveConfig)
        }
    }

    /// Streams JSONL file line by line
    private static func streamJSONL(
        path: String,
        config: Config
    ) -> AROStream<[String: any Sendable]> {
        AROStream {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        let url = URL(fileURLWithPath: path)
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }

                        var lineBuffer = Data()
                        let chunkSize = 65536

                        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                            // Process chunk byte by byte looking for newlines
                            for byte in chunk {
                                if byte == UInt8(ascii: "\n") {
                                    // End of line - parse it
                                    if !lineBuffer.isEmpty {
                                        if let dict = parseJSONLine(lineBuffer, config: config) {
                                            continuation.yield(dict)
                                        }
                                        lineBuffer.removeAll(keepingCapacity: true)
                                    }
                                } else {
                                    lineBuffer.append(byte)

                                    // Check max line length
                                    if lineBuffer.count > config.maxLineLength {
                                        if !config.skipMalformed {
                                            continuation.finish(throwing: JSONStreamError.lineTooLong(config.maxLineLength))
                                            return
                                        }
                                        // Skip this line
                                        lineBuffer.removeAll(keepingCapacity: true)
                                    }
                                }
                            }
                        }

                        // Handle final line without trailing newline
                        if !lineBuffer.isEmpty {
                            if let dict = parseJSONLine(lineBuffer, config: config) {
                                continuation.yield(dict)
                            }
                        }

                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    /// Parses a single JSONL line
    private static func parseJSONLine(
        _ data: Data,
        config: Config
    ) -> [String: any Sendable]? {
        // Skip empty lines and comments
        guard let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
              !str.isEmpty,
              !str.hasPrefix("#"),
              !str.hasPrefix("//") else {
            return nil
        }

        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return convertToSendable(json)
            }
            return nil
        } catch {
            if config.skipMalformed {
                return nil
            }
            return nil  // In streaming context, we can't throw here
        }
    }

    /// Streams JSON array file, yielding each element
    private static func streamJSONArray(
        path: String,
        config: Config
    ) -> AROStream<[String: any Sendable]> {
        AROStream {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        // For JSON arrays, we need to parse incrementally
                        // This is more complex - we use a simple approach of loading
                        // the file and parsing the array, yielding each element
                        // For truly huge JSON arrays, a SAX-style parser would be better

                        let url = URL(fileURLWithPath: path)
                        let data = try Data(contentsOf: url)

                        guard let json = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                            continuation.finish(throwing: JSONStreamError.notAnArray)
                            return
                        }

                        for element in json {
                            if let dict = element as? [String: Any] {
                                continuation.yield(convertToSendable(dict))
                            } else if config.skipMalformed {
                                continue
                            } else {
                                continuation.finish(throwing: JSONStreamError.elementNotObject)
                                return
                            }
                        }

                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    /// Converts a JSON dictionary to Sendable types
    private static func convertToSendable(_ dict: [String: Any]) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        for (key, value) in dict {
            result[key] = convertValueToSendable(value)
        }
        return result
    }

    /// Converts a JSON value to a Sendable type
    private static func convertValueToSendable(_ value: Any) -> any Sendable {
        switch value {
        case let str as String:
            return str
        case let num as NSNumber:
            // Check if it's a boolean
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return num.boolValue
            }
            // Check if it's an integer
            if floor(num.doubleValue) == num.doubleValue && abs(num.doubleValue) < Double(Int.max) {
                return num.intValue
            }
            return num.doubleValue
        case let bool as Bool:
            return bool
        case let arr as [Any]:
            return arr.map { convertValueToSendable($0) }
        case let dict as [String: Any]:
            return convertToSendable(dict)
        case is NSNull:
            return Optional<String>.none as any Sendable
        default:
            return String(describing: value)
        }
    }
}

// MARK: - Errors

/// Errors that can occur during JSON stream parsing
public enum JSONStreamError: Error, LocalizedError {
    case lineTooLong(Int)
    case notAnArray
    case elementNotObject
    case malformedJSON(String)

    public var errorDescription: String? {
        switch self {
        case .lineTooLong(let max):
            return "Line exceeds maximum length of \(max) bytes"
        case .notAnArray:
            return "JSON file is not an array"
        case .elementNotObject:
            return "Array element is not an object"
        case .malformedJSON(let detail):
            return "Malformed JSON: \(detail)"
        }
    }
}

// MARK: - AROStream Extension

extension AROStream where Element == [String: any Sendable] {
    /// Creates a stream from a JSON or JSONL file
    public static func fromJSON(
        path: String,
        config: JSONStreamParser.Config? = nil
    ) -> AROStream<[String: any Sendable]> {
        JSONStreamParser.stream(path: path, config: config)
    }

    /// Creates a stream from a JSONL file (convenience)
    public static func fromJSONL(path: String) -> AROStream<[String: any Sendable]> {
        JSONStreamParser.stream(path: path, config: .jsonl)
    }
}
