// ============================================================
// CSVPlugin.swift
// ARO Plugin - CSV Processing Service
// ============================================================
//
// Provides CSV parsing and formatting functionality.
//
// Usage in ARO:
//   <Call> the <result> from the <csv-plugin: parse-csv> with { data: "..." }.
//   <Call> the <result> from the <csv-plugin: csv-to-json> with { data: "..." }.
//   <Call> the <result> from the <csv-plugin: format-csv> with { rows: [...] }.

import Foundation

// MARK: - Plugin Initialization

@_cdecl("aro_plugin_init")
public func pluginInit() -> UnsafePointer<CChar> {
    let metadata = """
    {"services": [{"name": "csv-plugin", "symbol": "csv_plugin_call", "methods": ["parse-csv", "csvtojson", "format-csv"]}]}
    """
    return UnsafePointer(strdup(metadata)!)
}

// MARK: - Service Implementation

@_cdecl("csv_plugin_call")
public func csvPluginCall(
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

    let result: [String: Any]

    switch method.lowercased() {
    case "parse-csv":
        result = parseCSV(args)

    case "csv-to-json", "csvtojson":
        result = csvToJSON(args)

    case "format-csv":
        result = formatCSV(args)

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

// MARK: - CSV Functions

private func parseCSV(_ args: [String: Any]) -> [String: Any] {
    guard let csvData = args["data"] as? String else {
        return ["error": "Missing 'data' field"]
    }

    let hasHeaders = args["headers"] as? Bool ?? true
    let lines = csvData.components(separatedBy: "\n").filter { !$0.isEmpty }

    var rows: [[String]] = []
    for line in lines {
        let fields = parseCSVLine(line)
        rows.append(fields)
    }

    return [
        "rows": rows,
        "row_count": rows.count
    ]
}

private func csvToJSON(_ args: [String: Any]) -> [String: Any] {
    guard let csvData = args["data"] as? String else {
        return ["error": "Missing 'data' field"]
    }

    let lines = csvData.components(separatedBy: "\n").filter { !$0.isEmpty }
    guard lines.count > 0 else {
        return ["objects": [], "count": 0]
    }

    let headers = parseCSVLine(lines[0])
    var objects: [[String: String]] = []

    for i in 1..<lines.count {
        let fields = parseCSVLine(lines[i])
        var obj: [String: String] = [:]
        for (j, header) in headers.enumerated() {
            if j < fields.count {
                obj[header] = fields[j]
            }
        }
        objects.append(obj)
    }

    return [
        "objects": objects,
        "count": objects.count
    ]
}

private func formatCSV(_ args: [String: Any]) -> [String: Any] {
    guard let rows = args["rows"] as? [[Any]] else {
        return ["error": "Missing 'rows' field"]
    }

    let delimiter = (args["delimiter"] as? String) ?? ","

    var csvLines: [String] = []
    for row in rows {
        let fields = row.map { value -> String in
            let str = "\(value)"
            if str.contains(delimiter) || str.contains("\"") || str.contains("\n") {
                return "\"\(str.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            return str
        }
        csvLines.append(fields.joined(separator: delimiter))
    }

    return ["csv": csvLines.joined(separator: "\n")]
}

private func parseCSVLine(_ line: String) -> [String] {
    var fields: [String] = []
    var current = ""
    var inQuotes = false

    for char in line {
        if char == "\"" {
            inQuotes.toggle()
        } else if char == "," && !inQuotes {
            fields.append(current)
            current = ""
        } else {
            current.append(char)
        }
    }
    fields.append(current)

    return fields
}
