// FormatDeserializer.swift - ARO-0040: Format-Aware File I/O
// Deserialization of file content to ARO values

import Foundation

/// Deserializes file content to ARO values based on file format
public struct FormatDeserializer: Sendable {

    /// Deserialize content from the specified format
    /// - Parameters:
    ///   - content: The file content as string
    ///   - format: Source file format
    ///   - options: Optional format-specific options (delimiter, header, quote)
    /// - Returns: Deserialized value (Map, Array, or String)
    public static func deserialize(
        _ content: String,
        format: FileFormat,
        options: [String: any Sendable] = [:]
    ) -> any Sendable {
        switch format {
        case .json:
            return deserializeJSON(content)
        case .jsonl:
            return deserializeJSONL(content)
        case .yaml:
            return deserializeYAML(content)
        case .xml:
            return deserializeXML(content)
        case .toml:
            return deserializeTOML(content)
        case .csv:
            let delimiter = (options["delimiter"] as? String) ?? ","
            let hasHeader = (options["header"] as? Bool) ?? true
            let quoteChar = (options["quote"] as? String) ?? "\""
            return deserializeCSV(content, delimiter: delimiter, hasHeader: hasHeader, quoteChar: quoteChar)
        case .tsv:
            let delimiter = (options["delimiter"] as? String) ?? "\t"
            let hasHeader = (options["header"] as? Bool) ?? true
            let quoteChar = (options["quote"] as? String) ?? "\""
            return deserializeCSV(content, delimiter: delimiter, hasHeader: hasHeader, quoteChar: quoteChar)
        case .text:
            return deserializeText(content)
        case .env:
            return deserializeEnv(content)
        case .markdown, .html, .sql, .log, .binary:
            // These formats don't support deserialization - return raw string
            return content
        }
    }

    // MARK: - JSON Deserialization

    private static func deserializeJSON(_ content: String) -> any Sendable {
        guard let data = content.data(using: .utf8) else {
            return content
        }
        do {
            let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
            return convertJSONToSendable(jsonObject)
        } catch {
            return content
        }
    }

    private static func convertJSONToSendable(_ value: Any) -> any Sendable {
        switch value {
        case let str as String:
            return str
        case let num as NSNumber:
            // Distinguish between Int, Double, and Bool
            // Use cross-platform approach to detect boolean type
            #if canImport(Darwin)
            let isBool = CFGetTypeID(num) == CFBooleanGetTypeID()
            #else
            // On Linux, check objCType - Bool uses "c" (char) with value 0 or 1
            let objCType = String(cString: num.objCType)
            let isBool = objCType == "c" && (num.intValue == 0 || num.intValue == 1)
            #endif
            if isBool {
                return num.boolValue
            } else if num.doubleValue == Double(num.intValue) {
                return num.intValue
            } else {
                return num.doubleValue
            }
        case let array as [Any]:
            return array.map { convertJSONToSendable($0) }
        case let dict as [String: Any]:
            var result: [String: any Sendable] = [:]
            for (key, val) in dict {
                result[key] = convertJSONToSendable(val)
            }
            return result
        case is NSNull:
            return ""
        default:
            return String(describing: value)
        }
    }

    // MARK: - JSONL Deserialization (JSON Lines)

    private static func deserializeJSONL(_ content: String) -> any Sendable {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }
        var result: [any Sendable] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            guard let data = trimmed.data(using: .utf8) else { continue }
            do {
                let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
                result.append(convertJSONToSendable(jsonObject))
            } catch {
                // Skip malformed lines
                continue
            }
        }

        return result
    }

    // MARK: - YAML Deserialization

    private static func deserializeYAML(_ content: String) -> any Sendable {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        return parseYAMLLines(lines, startIndex: 0, indent: 0).value
    }

    private static func parseYAMLLines(
        _ lines: [String],
        startIndex: Int,
        indent: Int
    ) -> (value: any Sendable, endIndex: Int) {
        guard startIndex < lines.count else {
            return ("", startIndex)
        }

        let line = lines[startIndex]
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)

        // Skip empty lines and comments
        if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
            return parseYAMLLines(lines, startIndex: startIndex + 1, indent: indent)
        }

        // Check for array item
        if trimmedLine.hasPrefix("- ") {
            return parseYAMLArray(lines, startIndex: startIndex, indent: indent)
        }

        // Check for key-value pair
        if trimmedLine.contains(":") {
            return parseYAMLObject(lines, startIndex: startIndex, indent: indent)
        }

        // Simple value
        return (parseYAMLScalar(trimmedLine), startIndex + 1)
    }

    private static func parseYAMLArray(
        _ lines: [String],
        startIndex: Int,
        indent: Int
    ) -> (value: [any Sendable], endIndex: Int) {
        var result: [any Sendable] = []
        var index = startIndex

        while index < lines.count {
            let line = lines[index]
            let currentIndent = line.prefix(while: { $0 == " " }).count

            if currentIndent < indent && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }

            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
                index += 1
                continue
            }

            if !trimmedLine.hasPrefix("- ") {
                break
            }

            // Parse array item
            let itemContent = String(trimmedLine.dropFirst(2))
            if itemContent.contains(": ") {
                // Inline object in array
                let (obj, _) = parseYAMLObject(
                    [itemContent] + Array(lines.dropFirst(index + 1)),
                    startIndex: 0,
                    indent: 0
                )
                result.append(obj)
                index += 1
            } else if itemContent.isEmpty {
                // Multi-line value after dash
                index += 1
            } else {
                result.append(parseYAMLScalar(itemContent))
                index += 1
            }
        }

        return (result, index)
    }

    private static func parseYAMLObject(
        _ lines: [String],
        startIndex: Int,
        indent: Int
    ) -> (value: [String: any Sendable], endIndex: Int) {
        var result: [String: any Sendable] = [:]
        var index = startIndex

        while index < lines.count {
            let line = lines[index]
            let currentIndent = line.prefix(while: { $0 == " " }).count

            if currentIndent < indent && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }

            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
                index += 1
                continue
            }

            if trimmedLine.hasPrefix("- ") {
                break
            }

            guard let colonIndex = trimmedLine.firstIndex(of: ":") else {
                index += 1
                continue
            }

            let key = String(trimmedLine[..<colonIndex])
            let afterColon = String(trimmedLine[trimmedLine.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)

            if afterColon.isEmpty {
                // Value is on next line(s)
                index += 1
                if index < lines.count {
                    let nextLine = lines[index]
                    let nextIndent = nextLine.prefix(while: { $0 == " " }).count
                    if nextLine.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                        let (arr, endIdx) = parseYAMLArray(lines, startIndex: index, indent: nextIndent)
                        result[key] = arr
                        index = endIdx
                    } else {
                        let (obj, endIdx) = parseYAMLObject(lines, startIndex: index, indent: nextIndent)
                        result[key] = obj
                        index = endIdx
                    }
                }
            } else {
                result[key] = parseYAMLScalar(afterColon)
                index += 1
            }
        }

        return (result, index)
    }

    private static func parseYAMLScalar(_ value: String) -> any Sendable {
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        // Boolean
        if trimmed == "true" || trimmed == "True" || trimmed == "TRUE" {
            return true
        }
        if trimmed == "false" || trimmed == "False" || trimmed == "FALSE" {
            return false
        }

        // Null
        if trimmed == "null" || trimmed == "~" || trimmed.isEmpty {
            return ""
        }

        // Number
        if let intValue = Int(trimmed) {
            return intValue
        }
        if let doubleValue = Double(trimmed) {
            return doubleValue
        }

        // Quoted string - remove quotes
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
           (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }

        return trimmed
    }

    // MARK: - XML Deserialization

    private static func deserializeXML(_ content: String) -> any Sendable {
        // Simple XML parser
        let stripped = content.replacingOccurrences(
            of: "<\\?xml[^>]*\\?>",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if let parsed = parseXMLElement(stripped) {
            return convertAnyToSendable(parsed)
        }
        return content
    }

    private static func convertAnyToSendable(_ value: Any) -> any Sendable {
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
            return array.map { convertAnyToSendable($0) }
        case let dict as [String: Any]:
            var result: [String: any Sendable] = [:]
            for (key, val) in dict {
                result[key] = convertAnyToSendable(val)
            }
            return result
        case let sendable as (any Sendable):
            return sendable
        default:
            return String(describing: value)
        }
    }

    private static func parseXMLElement(_ content: String) -> Any? {
        // Find the root element
        guard let startTagMatch = content.range(of: "<([a-zA-Z][a-zA-Z0-9_-]*)>", options: .regularExpression) else {
            return nil
        }

        let tagContent = String(content[startTagMatch])
        let tagName = String(tagContent.dropFirst().dropLast())

        // Find closing tag
        let closingTag = "</\(tagName)>"
        guard let closingRange = content.range(of: closingTag) else {
            return nil
        }

        let innerContent = String(content[startTagMatch.upperBound..<closingRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if inner content contains child elements
        if innerContent.contains("<") {
            // Parse child elements
            var children: [String: Any] = [:]
            var items: [Any] = []
            var remaining = innerContent

            while let childStart = remaining.range(of: "<([a-zA-Z][a-zA-Z0-9_-]*)>", options: .regularExpression) {
                let childTagContent = String(remaining[childStart])
                let childTagName = String(childTagContent.dropFirst().dropLast())
                let childClosing = "</\(childTagName)>"

                guard let childEnd = remaining.range(of: childClosing) else { break }

                let childInner = String(remaining[childStart.upperBound..<childEnd.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let childValue: Any
                if childInner.contains("<") {
                    childValue = parseXMLElement("<\(childTagName)>" + childInner + "</\(childTagName)>") ?? childInner
                } else {
                    childValue = parseXMLScalar(childInner)
                }

                if childTagName == "item" {
                    items.append(childValue)
                } else if let existing = children[childTagName] {
                    // Multiple elements with same name -> array
                    if var arr = existing as? [Any] {
                        arr.append(childValue)
                        children[childTagName] = arr
                    } else {
                        children[childTagName] = [existing, childValue]
                    }
                } else {
                    children[childTagName] = childValue
                }

                remaining = String(remaining[childEnd.upperBound...])
            }

            if !items.isEmpty {
                return items.map { item -> any Sendable in
                    if let dict = item as? [String: Any] {
                        return convertXMLToSendable(dict)
                    }
                    return convertAnyToSendable(item)
                }
            }
            return convertXMLToSendable(children)
        } else {
            // Leaf element
            return parseXMLScalar(innerContent)
        }
    }

    private static func convertXMLToSendable(_ dict: [String: Any]) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        for (key, value) in dict {
            if let nestedDict = value as? [String: Any] {
                result[key] = convertXMLToSendable(nestedDict)
            } else if let arr = value as? [Any] {
                result[key] = arr.map { item -> any Sendable in
                    if let d = item as? [String: Any] {
                        return convertXMLToSendable(d)
                    }
                    return convertAnyToSendable(item)
                }
            } else {
                result[key] = convertAnyToSendable(value)
            }
        }
        return result
    }

    private static func parseXMLScalar(_ value: String) -> any Sendable {
        let unescaped = value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")

        if let intValue = Int(unescaped) {
            return intValue
        }
        if let doubleValue = Double(unescaped) {
            return doubleValue
        }
        if unescaped == "true" { return true }
        if unescaped == "false" { return false }
        return unescaped
    }

    // MARK: - TOML Deserialization

    private static func deserializeTOML(_ content: String) -> any Sendable {
        var result: [String: any Sendable] = [:]
        var currentTable: String? = nil
        var arrayTables: [String: [[String: any Sendable]]] = [:]

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Array of tables
            if trimmed.hasPrefix("[[") && trimmed.hasSuffix("]]") {
                let tableName = String(trimmed.dropFirst(2).dropLast(2))
                currentTable = tableName
                if arrayTables[tableName] == nil {
                    arrayTables[tableName] = []
                }
                arrayTables[tableName]?.append([:])
                continue
            }

            // Table
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                currentTable = String(trimmed.dropFirst().dropLast())
                continue
            }

            // Key-value pair
            if let equalsIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
                let valueStr = String(trimmed[trimmed.index(after: equalsIndex)...])
                    .trimmingCharacters(in: .whitespaces)
                let value = parseTOMLValue(valueStr)

                if let table = currentTable, var tables = arrayTables[table], !tables.isEmpty {
                    tables[tables.count - 1][key] = value
                    arrayTables[table] = tables
                } else if let table = currentTable {
                    if result[table] == nil {
                        result[table] = [:] as [String: any Sendable]
                    }
                    if var tableDict = result[table] as? [String: any Sendable] {
                        tableDict[key] = value
                        result[table] = tableDict
                    }
                } else {
                    result[key] = value
                }
            }
        }

        // Merge array tables into result
        for (tableName, tables) in arrayTables {
            result[tableName] = tables
        }

        // If only one array table, return it directly
        if result.count == 1, let (_, value) = result.first, let arr = value as? [[String: any Sendable]] {
            return arr
        }

        return result
    }

    private static func parseTOMLValue(_ value: String) -> any Sendable {
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        // String (quoted)
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
           (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }

        // Boolean
        if trimmed == "true" { return true }
        if trimmed == "false" { return false }

        // Array
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            let inner = String(trimmed.dropFirst().dropLast())
            let items = splitTOMLArray(inner)
            return items.map { parseTOMLValue($0) }
        }

        // Inline table
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            var dict: [String: any Sendable] = [:]
            let inner = String(trimmed.dropFirst().dropLast())
            let pairs = inner.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            for pair in pairs {
                if let eqIdx = pair.firstIndex(of: "=") {
                    let key = String(pair[..<eqIdx]).trimmingCharacters(in: .whitespaces)
                    let val = String(pair[pair.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
                    dict[key] = parseTOMLValue(val)
                }
            }
            return dict
        }

        // Number
        if let intValue = Int(trimmed) {
            return intValue
        }
        if let doubleValue = Double(trimmed) {
            return doubleValue
        }

        return trimmed
    }

    private static func splitTOMLArray(_ content: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var stringChar: Character = "\""

        for char in content {
            if !inString {
                if char == "\"" || char == "'" {
                    inString = true
                    stringChar = char
                } else if char == "[" || char == "{" {
                    depth += 1
                } else if char == "]" || char == "}" {
                    depth -= 1
                } else if char == "," && depth == 0 {
                    result.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    continue
                }
            } else if char == stringChar {
                inString = false
            }
            current.append(char)
        }

        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append(current.trimmingCharacters(in: .whitespaces))
        }

        return result
    }

    // MARK: - CSV/TSV Deserialization

    private static func deserializeCSV(
        _ content: String,
        delimiter: String,
        hasHeader: Bool = true,
        quoteChar: String = "\""
    ) -> any Sendable {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        guard !lines.isEmpty else {
            return content
        }

        let quoteCharacter = quoteChar.first ?? "\""

        if hasHeader {
            guard lines.count >= 2 else {
                return content
            }

            // Parse header
            let headers = parseCSVLine(lines[0], delimiter: delimiter, quoteChar: quoteCharacter)

            // Check if this is a key-value style CSV
            if headers.count == 2 && headers[0].lowercased() == "key" && headers[1].lowercased() == "value" {
                var result: [String: any Sendable] = [:]
                for line in lines.dropFirst() where !line.isEmpty {
                    let values = parseCSVLine(line, delimiter: delimiter, quoteChar: quoteCharacter)
                    if values.count >= 2 {
                        result[values[0]] = parseCSVValue(values[1])
                    }
                }
                return result
            }

            // Parse as array of objects
            var result: [[String: any Sendable]] = []
            for line in lines.dropFirst() where !line.isEmpty {
                let values = parseCSVLine(line, delimiter: delimiter, quoteChar: quoteCharacter)
                var row: [String: any Sendable] = [:]
                for (index, header) in headers.enumerated() where index < values.count {
                    row[header] = parseCSVValue(values[index])
                }
                result.append(row)
            }
            return result
        } else {
            // No header - return array of arrays
            var result: [[any Sendable]] = []
            for line in lines where !line.isEmpty {
                let values = parseCSVLine(line, delimiter: delimiter, quoteChar: quoteCharacter)
                result.append(values.map { parseCSVValue($0) })
            }
            return result
        }
    }

    private static func parseCSVLine(_ line: String, delimiter: String, quoteChar: Character = "\"") -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false

        let delimChar = delimiter.first ?? ","

        for char in line {
            if char == quoteChar {
                inQuotes.toggle()
            } else if char == delimChar && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current)

        return result.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseCSVValue(_ value: String) -> any Sendable {
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        if let intValue = Int(trimmed) {
            return intValue
        }
        if let doubleValue = Double(trimmed) {
            return doubleValue
        }
        if trimmed.lowercased() == "true" { return true }
        if trimmed.lowercased() == "false" { return false }

        return trimmed
    }

    // MARK: - Plain Text Deserialization

    private static func deserializeText(_ content: String) -> any Sendable {
        var result: [String: any Sendable] = [:]
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }

        for line in lines {
            guard let equalsIndex = line.firstIndex(of: "=") else { continue }

            let key = String(line[..<equalsIndex])
            let value = String(line[line.index(after: equalsIndex)...])

            // Handle dot notation for nested objects
            let parts = key.split(separator: ".").map { String($0) }
            if parts.count > 1 {
                setNestedValue(&result, parts: parts, value: parseTextValue(value))
            } else {
                result[key] = parseTextValue(value)
            }
        }

        return result
    }

    private static func setNestedValue(
        _ dict: inout [String: any Sendable],
        parts: [String],
        value: any Sendable
    ) {
        guard let first = parts.first else { return }

        if parts.count == 1 {
            dict[first] = value
        } else {
            var nested = (dict[first] as? [String: any Sendable]) ?? [:]
            setNestedValue(&nested, parts: Array(parts.dropFirst()), value: value)
            dict[first] = nested
        }
    }

    private static func parseTextValue(_ value: String) -> any Sendable {
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        if let intValue = Int(trimmed) {
            return intValue
        }
        if let doubleValue = Double(trimmed) {
            return doubleValue
        }
        if trimmed == "true" { return true }
        if trimmed == "false" { return false }

        return trimmed
    }

    // MARK: - Environment File Deserialization

    private static func deserializeEnv(_ content: String) -> any Sendable {
        var result: [String: any Sendable] = [:]
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Parse KEY=VALUE
            if let equalsIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<equalsIndex])
                let value = String(trimmed[trimmed.index(after: equalsIndex)...])
                result[key] = parseEnvValue(value)
            }
        }

        return result
    }

    private static func parseEnvValue(_ value: String) -> any Sendable {
        // Remove surrounding quotes if present
        var trimmed = value
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
           (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            trimmed = String(trimmed.dropFirst().dropLast())
        }

        // Try to parse as Int
        if let intValue = Int(trimmed) {
            return intValue
        }

        // Try to parse as Double
        if let doubleValue = Double(trimmed) {
            return doubleValue
        }

        // Try to parse as Bool
        if trimmed.lowercased() == "true" {
            return true
        }
        if trimmed.lowercased() == "false" {
            return false
        }

        return trimmed
    }
}
