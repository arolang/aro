// ============================================================
// ZipService.swift
// ARO Plugin - Zip file compression using marmelroy/Zip library
// ============================================================
//
// This plugin demonstrates using external Swift Package dependencies
// in ARO plugins. It provides file compression capabilities.
//
// Usage in ARO:
//   <Call> the <result> from the <zip: compress> with {
//       files: ["file1.txt", "file2.txt"],
//       output: "archive.zip"
//   }.

import Foundation
import Zip

// MARK: - Plugin Initialization

/// Plugin initialization - returns service metadata as JSON
/// This tells ARO what services and symbols this plugin provides
@_cdecl("aro_plugin_init")
public func pluginInit() -> UnsafePointer<CChar> {
    let metadata = """
    {"services": [{"name": "zip", "symbol": "zip_call"}]}
    """
    let cstr = strdup(metadata)!
    return UnsafePointer(cstr)
}

// MARK: - Service Implementation

/// Main entry point for the zip service
/// - Parameters:
///   - methodPtr: Method name (C string)
///   - argsPtr: Arguments as JSON (C string)
///   - resultPtr: Output - result as JSON (caller must free)
/// - Returns: 0 for success, non-zero for error
@_cdecl("zip_call")
public func zipCall(
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

    // Execute method
    do {
        let result = try executeMethod(method, args: args)
        let resultJSON = try encodeResult(result)
        resultPtr.pointee = resultJSON.withCString { strdup($0) }
        return 0
    } catch {
        // Return error message
        let errorJSON = "{\"error\": \"\(escapeJSON(String(describing: error)))\"}"
        resultPtr.pointee = errorJSON.withCString { strdup($0) }
        return 1
    }
}

/// Execute a zip method
private func executeMethod(_ method: String, args: [String: Any]) throws -> [String: Any] {
    switch method.lowercased() {
    case "compress", "zip":
        return try compress(args: args)

    case "decompress", "unzip":
        return try decompress(args: args)

    case "list":
        return try listContents(args: args)

    default:
        throw ZipPluginError.unknownMethod(method)
    }
}

/// Compress files into a zip archive
private func compress(args: [String: Any]) throws -> [String: Any] {
    guard let files = args["files"] as? [String] else {
        throw ZipPluginError.missingArgument("files")
    }

    guard let outputPath = args["output"] as? String else {
        throw ZipPluginError.missingArgument("output")
    }

    // Convert to URLs
    let fileURLs = files.map { URL(fileURLWithPath: $0) }
    let outputURL = URL(fileURLWithPath: outputPath)

    // Verify all input files exist
    for fileURL in fileURLs {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ZipPluginError.fileNotFound(fileURL.path)
        }
    }

    // Create zip archive
    try Zip.zipFiles(paths: fileURLs, zipFilePath: outputURL, password: nil, progress: nil)

    return [
        "success": true,
        "output": outputPath,
        "filesCompressed": files.count
    ]
}

/// Decompress a zip archive
private func decompress(args: [String: Any]) throws -> [String: Any] {
    guard let archivePath = args["archive"] as? String else {
        throw ZipPluginError.missingArgument("archive")
    }

    let destination = args["destination"] as? String ?? "."

    let archiveURL = URL(fileURLWithPath: archivePath)
    let destinationURL = URL(fileURLWithPath: destination)

    guard FileManager.default.fileExists(atPath: archiveURL.path) else {
        throw ZipPluginError.fileNotFound(archivePath)
    }

    // Extract archive
    try Zip.unzipFile(archiveURL, destination: destinationURL, overwrite: true, password: nil)

    return [
        "success": true,
        "destination": destination
    ]
}

/// List contents of a zip archive
private func listContents(args: [String: Any]) throws -> [String: Any] {
    guard let archivePath = args["archive"] as? String else {
        throw ZipPluginError.missingArgument("archive")
    }

    let archiveURL = URL(fileURLWithPath: archivePath)

    guard FileManager.default.fileExists(atPath: archiveURL.path) else {
        throw ZipPluginError.fileNotFound(archivePath)
    }

    // Get file list - unzip to temp to list
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: tempDir)
    }

    try Zip.unzipFile(archiveURL, destination: tempDir, overwrite: true, password: nil)

    // List extracted files
    var files: [String] = []
    let prefixToRemove = tempDir.path + "/"
    if let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil) {
        while let fileURL = enumerator.nextObject() as? URL {
            let fullPath = fileURL.path
            // Use pure Swift string handling to avoid Foundation bridging issues
            if fullPath.hasPrefix(prefixToRemove) {
                let relativePath = String(fullPath.dropFirst(prefixToRemove.count))
                files.append(relativePath)
            } else {
                files.append(fullPath)
            }
        }
    }

    return [
        "archive": archivePath,
        "files": files
    ]
}

/// Encode result as JSON string
private func encodeResult(_ result: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: result)
    return String(data: data, encoding: .utf8) ?? "{}"
}

/// Escape string for JSON
/// Uses manual character replacement to avoid Foundation bridging issues
private func escapeJSON(_ string: String) -> String {
    var result = ""
    result.reserveCapacity(string.count)
    for char in string {
        switch char {
        case "\\": result += "\\\\"
        case "\"": result += "\\\""
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        default: result.append(char)
        }
    }
    return result
}

// MARK: - Errors

/// Plugin-specific errors
enum ZipPluginError: Error, CustomStringConvertible {
    case unknownMethod(String)
    case missingArgument(String)
    case fileNotFound(String)

    var description: String {
        switch self {
        case .unknownMethod(let method):
            return "Unknown method: \(method). Available: compress, decompress, list"
        case .missingArgument(let arg):
            return "Missing required argument: \(arg)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        }
    }
}
