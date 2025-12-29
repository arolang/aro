// FormatSerializer.swift - ARO-0040: Format-Aware File I/O
// Serialization of ARO values to various file formats

import Foundation

/// Serializes ARO values to string representations based on file format
public struct FormatSerializer: Sendable {

    /// Serialize a value to the specified format
    /// - Parameters:
    ///   - value: The value to serialize
    ///   - format: Target file format
    ///   - variableName: Variable name (used as root element for XML/SQL)
    ///   - options: Optional format-specific options (delimiter, header, quote, encoding)
    /// - Returns: Serialized string representation
    public static func serialize(
        _ value: any Sendable,
        format: FileFormat,
        variableName: String,
        options: [String: any Sendable] = [:]
    ) -> String {
        switch format {
        case .json:
            return serializeJSON(value)
        case .jsonl:
            return serializeJSONL(value)
        case .yaml:
            return serializeYAML(value)
        case .xml:
            return serializeXML(value, rootName: variableName)
        case .toml:
            return serializeTOML(value, tableName: variableName)
        case .csv:
            let delimiter = (options["delimiter"] as? String) ?? ","
            let includeHeader = (options["header"] as? Bool) ?? true
            let quoteChar = (options["quote"] as? String) ?? "\""
            return serializeCSV(value, delimiter: delimiter, includeHeader: includeHeader, quoteChar: quoteChar)
        case .tsv:
            let delimiter = (options["delimiter"] as? String) ?? "\t"
            let includeHeader = (options["header"] as? Bool) ?? true
            let quoteChar = (options["quote"] as? String) ?? "\""
            return serializeCSV(value, delimiter: delimiter, includeHeader: includeHeader, quoteChar: quoteChar)
        case .markdown:
            return serializeMarkdown(value)
        case .html:
            return serializeHTML(value)
        case .text:
            return serializeText(value)
        case .sql:
            return serializeSQL(value, tableName: variableName)
        case .log:
            return serializeLog(value)
        case .env:
            return serializeEnv(value)
        case .binary:
            // Binary format: convert to string representation
            if let str = value as? String {
                return str
            }
            return String(describing: value)
        }
    }

    // MARK: - JSON Serialization

    private static func serializeJSON(_ value: any Sendable) -> String {
        var jsonValue = convertToJSONSerializable(value)

        // Ensure we have a valid top-level JSON type (array or object)
        // Wrap primitives in an object if needed
        if !JSONSerialization.isValidJSONObject(jsonValue) {
            // Try wrapping in an object or converting to string representation
            switch jsonValue {
            case let str as String:
                return "\"\(escapeJSON(str))\""
            case let num as Int:
                return String(num)
            case let num as Double:
                return String(num)
            case let bool as Bool:
                return bool ? "true" : "false"
            default:
                // Last resort: try to describe the value as JSON-like
                jsonValue = ["value": jsonValue]
            }
        }

        do {
            let data = try JSONSerialization.data(
                withJSONObject: jsonValue,
                options: [.prettyPrinted, .sortedKeys]
            )
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            // Fallback for non-JSON-serializable values
            if let str = value as? String {
                return "\"\(escapeJSON(str))\""
            }
            // Try to build JSON manually
            return buildJSONManually(value)
        }
    }

    /// Build JSON string manually for types that JSONSerialization can't handle
    private static func buildJSONManually(_ value: any Sendable) -> String {
        switch value {
        case let str as String:
            return "\"\(escapeJSON(str))\""
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(double)
        case let bool as Bool:
            return bool ? "true" : "false"
        case let array as [any Sendable]:
            let elements = array.map { buildJSONManually($0) }
            return "[\(elements.joined(separator: ", "))]"
        case let dict as [String: any Sendable]:
            let pairs = dict.keys.sorted().map { key in
                "\"\(escapeJSON(key))\": \(buildJSONManually(dict[key]!))"
            }
            return "{\(pairs.joined(separator: ", "))}"
        case let dict as [String: Any]:
            let pairs = dict.keys.sorted().map { key in
                "\"\(escapeJSON(key))\": \(buildJSONManuallyAny(dict[key]!))"
            }
            return "{\(pairs.joined(separator: ", "))}"
        case let array as [Any]:
            let elements = array.map { buildJSONManuallyAny($0) }
            return "[\(elements.joined(separator: ", "))]"
        default:
            return "\"\(escapeJSON(String(describing: value)))\""
        }
    }

    /// Build JSON string manually for Any types
    private static func buildJSONManuallyAny(_ value: Any) -> String {
        switch value {
        case let str as String:
            return "\"\(escapeJSON(str))\""
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(double)
        case let bool as Bool:
            return bool ? "true" : "false"
        case let array as [Any]:
            let elements = array.map { buildJSONManuallyAny($0) }
            return "[\(elements.joined(separator: ", "))]"
        case let dict as [String: Any]:
            let pairs = dict.keys.sorted().map { key in
                "\"\(escapeJSON(key))\": \(buildJSONManuallyAny(dict[key]!))"
            }
            return "{\(pairs.joined(separator: ", "))}"
        case let sendable as (any Sendable):
            return buildJSONManually(sendable)
        default:
            return "\"\(escapeJSON(String(describing: value)))\""
        }
    }

    // MARK: - JSONL Serialization (JSON Lines)

    private static func serializeJSONL(_ value: any Sendable) -> String {
        switch value {
        case let array as [any Sendable]:
            // Each array element on its own line as compact JSON
            return array.map { item in
                serializeJSONCompact(item)
            }.joined(separator: "\n")
        default:
            // Single value - output as single line
            return serializeJSONCompact(value)
        }
    }

    private static func serializeJSONCompact(_ value: any Sendable) -> String {
        let jsonValue = convertToJSONSerializable(value)
        do {
            let data = try JSONSerialization.data(
                withJSONObject: jsonValue,
                options: [.sortedKeys]  // No prettyPrinted - compact output
            )
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            if let str = value as? String {
                return "\"\(escapeJSON(str))\""
            }
            return String(describing: value)
        }
    }

    // MARK: - YAML Serialization

    private static func serializeYAML(_ value: any Sendable) -> String {
        return serializeYAMLValue(value, indent: 0)
    }

    private static func serializeYAMLValue(_ value: any Sendable, indent: Int) -> String {
        let indentStr = String(repeating: "  ", count: indent)

        switch value {
        case let str as String:
            if str.contains("\n") || str.contains(":") || str.contains("#") {
                return "|\n" + str.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { indentStr + "  " + $0 }.joined(separator: "\n")
            }
            return str
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(double)
        case let bool as Bool:
            return bool ? "true" : "false"
        case let array as [any Sendable]:
            if array.isEmpty { return "[]" }
            return array.map { item in
                let itemYaml = serializeYAMLValue(item, indent: indent + 1)
                if item is [String: any Sendable] {
                    // Object in array - format with proper indentation
                    let lines = itemYaml.split(separator: "\n", omittingEmptySubsequences: false)
                    if let first = lines.first {
                        let rest = lines.dropFirst().map { String($0) }.joined(separator: "\n")
                        return indentStr + "- " + first + (rest.isEmpty ? "" : "\n" + rest)
                    }
                }
                return indentStr + "- " + itemYaml
            }.joined(separator: "\n")
        case let dict as [String: any Sendable]:
            if dict.isEmpty { return "{}" }
            return dict.keys.sorted().map { key in
                let val = dict[key]!
                let valYaml = serializeYAMLValue(val, indent: indent + 1)
                if val is [any Sendable] || val is [String: any Sendable] {
                    return indentStr + key + ":\n" + valYaml
                }
                return indentStr + key + ": " + valYaml
            }.joined(separator: "\n")
        default:
            return String(describing: value)
        }
    }

    // MARK: - XML Serialization

    private static func serializeXML(_ value: any Sendable, rootName: String) -> String {
        var result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        result += serializeXMLElement(value, name: rootName, indent: 0)
        return result
    }

    private static func serializeXMLElement(_ value: any Sendable, name: String, indent: Int) -> String {
        let indentStr = String(repeating: "  ", count: indent)

        switch value {
        case let str as String:
            return indentStr + "<\(name)>\(escapeXML(str))</\(name)>"
        case let int as Int:
            return indentStr + "<\(name)>\(int)</\(name)>"
        case let double as Double:
            return indentStr + "<\(name)>\(double)</\(name)>"
        case let bool as Bool:
            return indentStr + "<\(name)>\(bool)</\(name)>"
        case let array as [any Sendable]:
            var lines: [String] = []
            lines.append(indentStr + "<\(name)>")
            for item in array {
                lines.append(serializeXMLElement(item, name: "item", indent: indent + 1))
            }
            lines.append(indentStr + "</\(name)>")
            return lines.joined(separator: "\n")
        case let dict as [String: any Sendable]:
            var lines: [String] = []
            lines.append(indentStr + "<\(name)>")
            for key in dict.keys.sorted() {
                lines.append(serializeXMLElement(dict[key]!, name: key, indent: indent + 1))
            }
            lines.append(indentStr + "</\(name)>")
            return lines.joined(separator: "\n")
        default:
            return indentStr + "<\(name)>\(escapeXML(String(describing: value)))</\(name)>"
        }
    }

    // MARK: - TOML Serialization

    private static func serializeTOML(_ value: any Sendable, tableName: String) -> String {
        switch value {
        case let array as [any Sendable]:
            // Array of objects -> array of tables
            return array.compactMap { item -> String? in
                guard let dict = item as? [String: any Sendable] else { return nil }
                var lines = ["[[\(tableName)]]"]
                for key in dict.keys.sorted() {
                    lines.append(serializeTOMLKeyValue(key: key, value: dict[key]!))
                }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n\n")
        case let dict as [String: any Sendable]:
            // Single object -> key-value pairs
            return dict.keys.sorted().map { key in
                serializeTOMLKeyValue(key: key, value: dict[key]!)
            }.joined(separator: "\n")
        default:
            return String(describing: value)
        }
    }

    private static func serializeTOMLKeyValue(key: String, value: any Sendable) -> String {
        switch value {
        case let str as String:
            return "\(key) = \"\(escapeTOML(str))\""
        case let int as Int:
            return "\(key) = \(int)"
        case let double as Double:
            return "\(key) = \(double)"
        case let bool as Bool:
            return "\(key) = \(bool)"
        case let array as [any Sendable]:
            let items = array.map { serializeTOMLValue($0) }.joined(separator: ", ")
            return "\(key) = [\(items)]"
        case let dict as [String: any Sendable]:
            let items = dict.keys.sorted().map { k in
                "\(k) = \(serializeTOMLValue(dict[k]!))"
            }.joined(separator: ", ")
            return "\(key) = { \(items) }"
        default:
            return "\(key) = \"\(String(describing: value))\""
        }
    }

    private static func serializeTOMLValue(_ value: any Sendable) -> String {
        switch value {
        case let str as String:
            return "\"\(escapeTOML(str))\""
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(double)
        case let bool as Bool:
            return String(bool)
        default:
            return "\"\(String(describing: value))\""
        }
    }

    // MARK: - CSV/TSV Serialization

    private static func serializeCSV(
        _ value: any Sendable,
        delimiter: String,
        includeHeader: Bool = true,
        quoteChar: String = "\""
    ) -> String {
        switch value {
        case let array as [any Sendable]:
            guard let firstDict = array.first as? [String: any Sendable] else {
                // Not array of objects - serialize as single column
                return array.map { escapeCSV(String(describing: $0), delimiter: delimiter, quoteChar: quoteChar) }
                    .joined(separator: "\n")
            }
            // Array of objects - header row + data rows
            let headers = firstDict.keys.sorted()
            var lines: [String] = []
            if includeHeader {
                lines.append(headers.map { escapeCSV($0, delimiter: delimiter, quoteChar: quoteChar) }.joined(separator: delimiter))
            }
            for item in array {
                if let dict = item as? [String: any Sendable] {
                    let row = headers.map { key -> String in
                        if let val = dict[key] {
                            return escapeCSV(stringValue(val), delimiter: delimiter, quoteChar: quoteChar)
                        }
                        return ""
                    }
                    lines.append(row.joined(separator: delimiter))
                }
            }
            return lines.joined(separator: "\n")
        case let dict as [String: any Sendable]:
            // Single object - key,value format
            var lines: [String] = []
            if includeHeader {
                lines.append("key\(delimiter)value")
            }
            for key in dict.keys.sorted() {
                let val = escapeCSV(stringValue(dict[key]!), delimiter: delimiter, quoteChar: quoteChar)
                lines.append("\(escapeCSV(key, delimiter: delimiter, quoteChar: quoteChar))\(delimiter)\(val)")
            }
            return lines.joined(separator: "\n")
        default:
            return String(describing: value)
        }
    }

    // MARK: - Markdown Serialization

    private static func serializeMarkdown(_ value: any Sendable) -> String {
        switch value {
        case let array as [any Sendable]:
            guard let firstDict = array.first as? [String: any Sendable] else {
                // Not array of objects - simple list
                return array.map { "- \(String(describing: $0))" }.joined(separator: "\n")
            }
            // Array of objects - table
            let headers = firstDict.keys.sorted()
            var lines: [String] = []
            lines.append("| " + headers.joined(separator: " | ") + " |")
            lines.append("|" + headers.map { _ in "---" }.joined(separator: "|") + "|")
            for item in array {
                if let dict = item as? [String: any Sendable] {
                    let row = headers.map { key -> String in
                        if let val = dict[key] {
                            return escapeMarkdown(stringValue(val))
                        }
                        return ""
                    }
                    lines.append("| " + row.joined(separator: " | ") + " |")
                }
            }
            return lines.joined(separator: "\n")
        case let dict as [String: any Sendable]:
            // Single object - key-value table
            var lines: [String] = []
            lines.append("| Key | Value |")
            lines.append("|-----|-------|")
            for key in dict.keys.sorted() {
                let val = escapeMarkdown(stringValue(dict[key]!))
                lines.append("| \(key) | \(val) |")
            }
            return lines.joined(separator: "\n")
        default:
            return String(describing: value)
        }
    }

    // MARK: - HTML Serialization

    private static func serializeHTML(_ value: any Sendable) -> String {
        switch value {
        case let array as [any Sendable]:
            guard let firstDict = array.first as? [String: any Sendable] else {
                // Not array of objects - simple list
                return "<ul>\n" + array.map { "  <li>\(escapeHTML(String(describing: $0)))</li>" }
                    .joined(separator: "\n") + "\n</ul>"
            }
            // Array of objects - table
            let headers = firstDict.keys.sorted()
            var lines: [String] = []
            lines.append("<table>")
            lines.append("  <thead>")
            lines.append("    <tr>" + headers.map { "<th>\(escapeHTML($0))</th>" }.joined() + "</tr>")
            lines.append("  </thead>")
            lines.append("  <tbody>")
            for item in array {
                if let dict = item as? [String: any Sendable] {
                    let cells = headers.map { key -> String in
                        if let val = dict[key] {
                            return "<td>\(escapeHTML(stringValue(val)))</td>"
                        }
                        return "<td></td>"
                    }
                    lines.append("    <tr>" + cells.joined() + "</tr>")
                }
            }
            lines.append("  </tbody>")
            lines.append("</table>")
            return lines.joined(separator: "\n")
        case let dict as [String: any Sendable]:
            // Single object - key-value table
            var lines: [String] = []
            lines.append("<table>")
            lines.append("  <thead>")
            lines.append("    <tr><th>Key</th><th>Value</th></tr>")
            lines.append("  </thead>")
            lines.append("  <tbody>")
            for key in dict.keys.sorted() {
                let val = escapeHTML(stringValue(dict[key]!))
                lines.append("    <tr><td>\(escapeHTML(key))</td><td>\(val)</td></tr>")
            }
            lines.append("  </tbody>")
            lines.append("</table>")
            return lines.joined(separator: "\n")
        default:
            return escapeHTML(String(describing: value))
        }
    }

    // MARK: - Plain Text Serialization

    private static func serializeText(_ value: any Sendable) -> String {
        return serializeTextValue(value, prefix: "")
    }

    private static func serializeTextValue(_ value: any Sendable, prefix: String) -> String {
        switch value {
        case let str as String:
            return str
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(double)
        case let bool as Bool:
            return String(bool)
        case let array as [any Sendable]:
            return array.enumerated().map { index, item in
                let itemPrefix = prefix.isEmpty ? "[\(index)]" : "\(prefix)[\(index)]"
                if let dict = item as? [String: any Sendable] {
                    return dict.keys.sorted().map { key in
                        "\(itemPrefix).\(key)=\(stringValue(dict[key]!))"
                    }.joined(separator: "\n")
                }
                return "\(itemPrefix)=\(stringValue(item))"
            }.joined(separator: "\n")
        case let dict as [String: any Sendable]:
            return dict.keys.sorted().map { key in
                let val = dict[key]!
                let keyPath = prefix.isEmpty ? key : "\(prefix).\(key)"
                if let nestedDict = val as? [String: any Sendable] {
                    return serializeTextValue(nestedDict, prefix: keyPath)
                }
                return "\(keyPath)=\(stringValue(val))"
            }.joined(separator: "\n")
        default:
            return String(describing: value)
        }
    }

    // MARK: - SQL Serialization

    private static func serializeSQL(_ value: any Sendable, tableName: String) -> String {
        switch value {
        case let array as [any Sendable]:
            return array.compactMap { item -> String? in
                guard let dict = item as? [String: any Sendable] else { return nil }
                return serializeSQLInsert(dict, tableName: tableName)
            }.joined(separator: "\n")
        case let dict as [String: any Sendable]:
            return serializeSQLInsert(dict, tableName: tableName)
        default:
            return "-- Cannot serialize non-object value to SQL"
        }
    }

    private static func serializeSQLInsert(_ dict: [String: any Sendable], tableName: String) -> String {
        let columns = dict.keys.sorted()
        let columnList = columns.joined(separator: ", ")
        let values = columns.map { key -> String in
            let val = dict[key]!
            return serializeSQLValue(val)
        }
        let valueList = values.joined(separator: ", ")
        return "INSERT INTO \(tableName) (\(columnList)) VALUES (\(valueList));"
    }

    private static func serializeSQLValue(_ value: any Sendable) -> String {
        switch value {
        case let str as String:
            return "'\(escapeSQL(str))'"
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(double)
        case let bool as Bool:
            return bool ? "TRUE" : "FALSE"
        case is NSNull:
            return "NULL"
        default:
            return "'\(escapeSQL(String(describing: value)))'"
        }
    }

    // MARK: - Log Serialization

    private static func serializeLog(_ value: any Sendable) -> String {
        let dateFormatter = ISO8601DateFormatter()
        let timestamp = dateFormatter.string(from: Date())

        switch value {
        case let array as [any Sendable]:
            // Multiple log entries - each gets its own timestamp
            return array.map { entry in
                let message = logStringValue(entry)
                return "\(timestamp): \(message)"
            }.joined(separator: "\n")
        case let array as [Any]:
            return array.map { entry in
                let message = logStringValueAny(entry)
                return "\(timestamp): \(message)"
            }.joined(separator: "\n")
        case let str as String:
            return "\(timestamp): \(str)"
        case let dict as [String: any Sendable]:
            return "\(timestamp): \(buildJSONManually(dict))"
        case let dict as [String: Any]:
            return "\(timestamp): \(buildJSONManuallyAny(dict))"
        default:
            return "\(timestamp): \(String(describing: value))"
        }
    }

    private static func logStringValue(_ value: any Sendable) -> String {
        switch value {
        case let str as String:
            return str
        case let dict as [String: any Sendable]:
            return buildJSONManually(dict)
        case let array as [any Sendable]:
            return buildJSONManually(array)
        default:
            return String(describing: value)
        }
    }

    private static func logStringValueAny(_ value: Any) -> String {
        switch value {
        case let str as String:
            return str
        case let dict as [String: Any]:
            return buildJSONManuallyAny(dict)
        case let array as [Any]:
            return buildJSONManuallyAny(array)
        default:
            return String(describing: value)
        }
    }

    // MARK: - Environment File Serialization

    private static func serializeEnv(_ value: any Sendable) -> String {
        var lines: [String] = []
        flattenToEnv(value, prefix: "", into: &lines)
        return lines.sorted().joined(separator: "\n")
    }

    private static func flattenToEnv(
        _ value: any Sendable,
        prefix: String,
        into lines: inout [String]
    ) {
        switch value {
        case let dict as [String: any Sendable]:
            for key in dict.keys.sorted() {
                let envKey = prefix.isEmpty ? key : "\(prefix)_\(key)"
                flattenToEnv(dict[key]!, prefix: envKey, into: &lines)
            }
        case let dict as [String: Any]:
            for key in dict.keys.sorted() {
                let envKey = prefix.isEmpty ? key : "\(prefix)_\(key)"
                flattenToEnvAny(dict[key]!, prefix: envKey, into: &lines)
            }
        case let str as String:
            lines.append("\(prefix.uppercased())=\(str)")
        case let int as Int:
            lines.append("\(prefix.uppercased())=\(int)")
        case let double as Double:
            lines.append("\(prefix.uppercased())=\(double)")
        case let bool as Bool:
            lines.append("\(prefix.uppercased())=\(bool)")
        case let array as [any Sendable]:
            // Flatten arrays with numeric indices
            for (index, item) in array.enumerated() {
                let envKey = prefix.isEmpty ? "\(index)" : "\(prefix)_\(index)"
                flattenToEnv(item, prefix: envKey, into: &lines)
            }
        default:
            lines.append("\(prefix.uppercased())=\(String(describing: value))")
        }
    }

    private static func flattenToEnvAny(
        _ value: Any,
        prefix: String,
        into lines: inout [String]
    ) {
        switch value {
        case let dict as [String: Any]:
            for key in dict.keys.sorted() {
                let envKey = prefix.isEmpty ? key : "\(prefix)_\(key)"
                flattenToEnvAny(dict[key]!, prefix: envKey, into: &lines)
            }
        case let sendable as (any Sendable):
            flattenToEnv(sendable, prefix: prefix, into: &lines)
        default:
            lines.append("\(prefix.uppercased())=\(String(describing: value))")
        }
    }

    // MARK: - Helper Methods

    private static func convertToJSONSerializable(_ value: any Sendable) -> Any {
        switch value {
        case let str as String:
            return str
        case let int as Int:
            return int
        case let double as Double:
            return double
        case let bool as Bool:
            return bool
        case let array as [any Sendable]:
            return array.map { convertToJSONSerializable($0) }
        case let dict as [String: any Sendable]:
            var result: [String: Any] = [:]
            for (key, val) in dict {
                result[key] = convertToJSONSerializable(val)
            }
            return result
        case let dict as [String: Any]:
            // Handle [String: Any] dictionaries from the runtime
            var result: [String: Any] = [:]
            for (key, val) in dict {
                result[key] = convertAnyToJSONSerializable(val)
            }
            return result
        case let array as [Any]:
            // Handle [Any] arrays from the runtime
            return array.map { convertAnyToJSONSerializable($0) }
        default:
            return String(describing: value)
        }
    }

    /// Convert Any type to JSON-serializable (for runtime values)
    private static func convertAnyToJSONSerializable(_ value: Any) -> Any {
        switch value {
        case let str as String:
            return str
        case let int as Int:
            return int
        case let double as Double:
            return double
        case let bool as Bool:
            return bool
        case let array as [Any]:
            return array.map { convertAnyToJSONSerializable($0) }
        case let dict as [String: Any]:
            var result: [String: Any] = [:]
            for (key, val) in dict {
                result[key] = convertAnyToJSONSerializable(val)
            }
            return result
        case let sendable as (any Sendable):
            return convertToJSONSerializable(sendable)
        default:
            return String(describing: value)
        }
    }

    private static func stringValue(_ value: any Sendable) -> String {
        switch value {
        case let str as String:
            return str
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(double)
        case let bool as Bool:
            return String(bool)
        default:
            return String(describing: value)
        }
    }

    // MARK: - Escape Functions

    private static func escapeJSON(_ str: String) -> String {
        var result = str
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "\"", with: "\\\"")
        result = result.replacingOccurrences(of: "\n", with: "\\n")
        result = result.replacingOccurrences(of: "\r", with: "\\r")
        result = result.replacingOccurrences(of: "\t", with: "\\t")
        return result
    }

    private static func escapeXML(_ str: String) -> String {
        var result = str
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&apos;")
        return result
    }

    private static func escapeTOML(_ str: String) -> String {
        var result = str
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "\"", with: "\\\"")
        result = result.replacingOccurrences(of: "\n", with: "\\n")
        result = result.replacingOccurrences(of: "\t", with: "\\t")
        return result
    }

    private static func escapeCSV(_ str: String, delimiter: String, quoteChar: String = "\"") -> String {
        if str.contains(delimiter) || str.contains(quoteChar) || str.contains("\n") {
            // Escape quote characters by doubling them
            let escaped = str.replacingOccurrences(of: quoteChar, with: quoteChar + quoteChar)
            return quoteChar + escaped + quoteChar
        }
        return str
    }

    private static func escapeMarkdown(_ str: String) -> String {
        var result = str
        result = result.replacingOccurrences(of: "|", with: "\\|")
        result = result.replacingOccurrences(of: "\n", with: " ")
        return result
    }

    private static func escapeHTML(_ str: String) -> String {
        var result = str
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        return result
    }

    private static func escapeSQL(_ str: String) -> String {
        return str.replacingOccurrences(of: "'", with: "''")
    }
}
