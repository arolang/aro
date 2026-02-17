// CSVStreamParser.swift
// ARO Streaming Execution Engine
//
// Incremental CSV parser that processes data chunk by chunk.

import Foundation

/// Incremental CSV parser that can process data in chunks.
///
/// Unlike traditional parsers that load the entire file, this parser
/// maintains state between chunks, allowing streaming of arbitrarily
/// large CSV files with constant memory usage.
///
/// Example:
/// ```swift
/// var parser = CSVStreamParser()
///
/// // Feed chunks as they arrive
/// for chunk in fileChunks {
///     for row in parser.feed(chunk) {
///         process(row)
///     }
/// }
///
/// // Get any remaining partial row
/// if let final = parser.flush() {
///     process(final)
/// }
/// ```
public struct CSVStreamParser: Sendable {

    /// Configuration for CSV parsing
    public struct Config: Sendable {
        public var delimiter: Character = ","
        public var quoteChar: Character = "\""
        public var hasHeader: Bool = true
        public var trimWhitespace: Bool = true

        public init(
            delimiter: Character = ",",
            quoteChar: Character = "\"",
            hasHeader: Bool = true,
            trimWhitespace: Bool = true
        ) {
            self.delimiter = delimiter
            self.quoteChar = quoteChar
            self.hasHeader = hasHeader
            self.trimWhitespace = trimWhitespace
        }

        /// TSV configuration
        public static var tsv: Config {
            Config(delimiter: "\t")
        }
    }

    /// Parser state
    private enum State: Sendable {
        case fieldStart
        case unquotedField
        case quotedField
        case quotedFieldMaybeEnd
        case lineEnd
    }

    private let config: Config
    private var state: State = .fieldStart
    private var headers: [String]?
    private var currentField: String = ""
    private var currentRow: [String] = []
    private var partialLine: String = ""
    private var rowCount: Int = 0

    /// Create a new CSV parser
    public init(config: Config = Config()) {
        self.config = config
    }

    /// Feed a chunk of data and get completed rows
    ///
    /// - Parameter chunk: Raw string data from the file
    /// - Returns: Array of parsed rows (as dictionaries if headers exist)
    public mutating func feed(_ chunk: String) -> [[String: any Sendable]] {
        var rows: [[String: any Sendable]] = []

        // Combine with any partial line from previous chunk
        let data = partialLine + chunk
        partialLine = ""

        for char in data {
            if let row = processCharacter(char) {
                if let dict = rowToDict(row) {
                    rows.append(dict)
                }
            }
        }

        return rows
    }

    /// Feed raw bytes (Data) and get completed rows
    public mutating func feed(_ data: Data) -> [[String: any Sendable]] {
        guard let str = String(data: data, encoding: .utf8) else {
            return []
        }
        return feed(str)
    }

    /// Flush any remaining partial data
    public mutating func flush() -> [String: any Sendable]? {
        // Complete any partial field
        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(processField(currentField))
            currentField = ""

            let row = currentRow
            currentRow = []

            return rowToDict(row)
        }

        // Handle any remaining partial line
        if !partialLine.isEmpty {
            let rows = feed("\n")  // Force line completion
            return rows.first
        }

        return nil
    }

    /// Process a single character
    private mutating func processCharacter(_ char: Character) -> [String]? {
        switch state {
        case .fieldStart:
            return handleFieldStart(char)
        case .unquotedField:
            return handleUnquotedField(char)
        case .quotedField:
            return handleQuotedField(char)
        case .quotedFieldMaybeEnd:
            return handleQuotedFieldMaybeEnd(char)
        case .lineEnd:
            return handleLineEnd(char)
        }
    }

    private mutating func handleFieldStart(_ char: Character) -> [String]? {
        if char == config.quoteChar {
            state = .quotedField
            return nil
        } else if char == config.delimiter {
            currentRow.append("")
            return nil
        } else if char == "\n" {
            return completeLine()
        } else if char == "\r" {
            state = .lineEnd
            return nil
        } else {
            currentField.append(char)
            state = .unquotedField
            return nil
        }
    }

    private mutating func handleUnquotedField(_ char: Character) -> [String]? {
        if char == config.delimiter {
            currentRow.append(processField(currentField))
            currentField = ""
            state = .fieldStart
            return nil
        } else if char == "\n" {
            return completeLine()
        } else if char == "\r" {
            state = .lineEnd
            return nil
        } else {
            currentField.append(char)
            return nil
        }
    }

    private mutating func handleQuotedField(_ char: Character) -> [String]? {
        if char == config.quoteChar {
            state = .quotedFieldMaybeEnd
            return nil
        } else {
            currentField.append(char)
            return nil
        }
    }

    private mutating func handleQuotedFieldMaybeEnd(_ char: Character) -> [String]? {
        if char == config.quoteChar {
            // Escaped quote
            currentField.append(config.quoteChar)
            state = .quotedField
            return nil
        } else if char == config.delimiter {
            currentRow.append(processField(currentField))
            currentField = ""
            state = .fieldStart
            return nil
        } else if char == "\n" {
            return completeLine()
        } else if char == "\r" {
            state = .lineEnd
            return nil
        } else {
            // Invalid CSV, but try to recover
            currentField.append(char)
            state = .unquotedField
            return nil
        }
    }

    private mutating func handleLineEnd(_ char: Character) -> [String]? {
        if char == "\n" {
            return completeLine()
        } else {
            // Standalone \r, treat as line end
            let row = completeLine()
            // Process this character as start of new line
            _ = processCharacter(char)
            return row
        }
    }

    private mutating func completeLine() -> [String]? {
        currentRow.append(processField(currentField))
        currentField = ""
        state = .fieldStart

        let row = currentRow
        currentRow = []
        rowCount += 1

        // First row might be headers
        if config.hasHeader && headers == nil {
            headers = row.map { normalizeHeader($0) }
            return nil
        }

        return row
    }

    private func processField(_ field: String) -> String {
        if config.trimWhitespace {
            return field.trimmingCharacters(in: .whitespaces)
        }
        return field
    }

    private func normalizeHeader(_ header: String) -> String {
        // Convert to kebab-case, replace dots and spaces with hyphens
        var normalized = header.trimmingCharacters(in: .whitespaces)
        normalized = normalized.replacingOccurrences(of: ".", with: "-")
        normalized = normalized.replacingOccurrences(of: " ", with: "-")
        normalized = normalized.lowercased()
        return normalized
    }

    private func rowToDict(_ row: [String]) -> [String: any Sendable]? {
        guard let headers = headers else {
            // No headers - return as indexed dictionary
            var dict: [String: any Sendable] = [:]
            for (i, value) in row.enumerated() {
                dict["col\(i)"] = parseValue(value)
            }
            return dict
        }

        // Map to headers
        var dict: [String: any Sendable] = [:]
        for (i, value) in row.enumerated() {
            if i < headers.count {
                dict[headers[i]] = parseValue(value)
            }
        }
        return dict
    }

    private func parseValue(_ str: String) -> any Sendable {
        // Try to parse as number
        if let intVal = Int(str) {
            return intVal
        }
        if let doubleVal = Double(str) {
            return doubleVal
        }

        // Try to parse as boolean
        let lower = str.lowercased()
        if lower == "true" || lower == "yes" || lower == "1" {
            return true
        }
        if lower == "false" || lower == "no" || lower == "0" {
            return false
        }

        // Return as string
        return str
    }

    /// Current row count (excluding header)
    public var parsedRowCount: Int { rowCount - (config.hasHeader ? 1 : 0) }

    /// The parsed headers (if any)
    public var parsedHeaders: [String]? { headers }

    /// Reset the parser state
    public mutating func reset() {
        state = .fieldStart
        headers = nil
        currentField = ""
        currentRow = []
        partialLine = ""
        rowCount = 0
    }
}

// MARK: - Streaming File Reader

extension AROStream where Element == [String: any Sendable] {
    /// Create a stream from a CSV file
    ///
    /// Reads the file in chunks for memory efficiency.
    ///
    /// - Parameters:
    ///   - path: Path to the CSV file
    ///   - config: CSV parser configuration
    ///   - chunkSize: Size of chunks to read (default: 64KB)
    public static func fromCSV(
        path: String,
        config: CSVStreamParser.Config = .init(),
        chunkSize: Int = 65536
    ) -> AROStream<[String: any Sendable]> {
        AROStream {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        let url = URL(fileURLWithPath: path)
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }

                        var parser = CSVStreamParser(config: config)

                        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                            for row in parser.feed(chunk) {
                                continuation.yield(row)
                            }
                        }

                        // Flush any remaining data
                        if let finalRow = parser.flush() {
                            continuation.yield(finalRow)
                        }

                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    /// Create a stream from CSV data
    public static func fromCSVData(
        _ data: Data,
        config: CSVStreamParser.Config = .init()
    ) -> AROStream<[String: any Sendable]> {
        AROStream {
            AsyncThrowingStream { continuation in
                var parser = CSVStreamParser(config: config)

                // Process data in chunks to simulate streaming
                let chunkSize = 65536
                var offset = 0

                while offset < data.count {
                    let end = Swift.min(offset + chunkSize, data.count)
                    let chunk = data[offset..<end]

                    for row in parser.feed(Data(chunk)) {
                        continuation.yield(row)
                    }

                    offset = end
                }

                if let finalRow = parser.flush() {
                    continuation.yield(finalRow)
                }

                continuation.finish()
            }
        }
    }

    /// Create a stream from a CSV string
    public static func fromCSVString(
        _ string: String,
        config: CSVStreamParser.Config = .init()
    ) -> AROStream<[String: any Sendable]> {
        guard let data = string.data(using: .utf8) else {
            return .empty
        }
        return fromCSVData(data, config: config)
    }
}
