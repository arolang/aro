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

// MARK: - Plugin Info

/// Returns full plugin metadata as JSON.
/// Declares this plugin provides a "zip" service with compress/decompress/list methods.
@_cdecl("aro_plugin_info")
public func aroPluginInfo() -> UnsafeMutablePointer<CChar> {
    let info = """
    {
      "name": "ZipPlugin",
      "version": "1.0.0",
      "handle": "Zip",
      "actions": [],
      "qualifiers": [],
      "services": [
        {
          "name": "zip",
          "methods": ["compress", "decompress", "list"]
        }
      ]
    }
    """
    return strdup(info)!
}

// MARK: - Lifecycle Hooks

/// Called once when the plugin is loaded. No setup required for the Zip library.
@_cdecl("aro_plugin_init")
public func aroPluginInit() {
    // No global state to initialise
}

/// Called when the plugin is unloaded. No teardown required.
@_cdecl("aro_plugin_shutdown")
public func aroPluginShutdown() {
    // No global state to release
}

// MARK: - Execute

/// Main dispatch function. Routes service actions via the "service:" prefix.
/// Action format: "service:<method>", e.g. "service:compress", "service:decompress", "service:list"
@_cdecl("aro_plugin_execute")
public func aroPluginExecute(
    _ actionPtr: UnsafePointer<CChar>,
    _ inputJSONPtr: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
    let action = String(cString: actionPtr)
    let inputJSON = String(cString: inputJSONPtr)

    // Parse arguments (allow empty object)
    var args: [String: Any] = [:]
    if let data = inputJSON.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        args = parsed
    }

    // Route service actions via "service:<method>" prefix
    guard action.hasPrefix("service:") else {
        return errorResponse("Unknown action: \(action)")
    }
    let method = String(action.dropFirst("service:".count))

    // Execute method
    do {
        let result = try executeMethod(method, args: args)
        return jsonResponse(result)
    } catch {
        return errorResponse(String(describing: error))
    }
}

// MARK: - Free

/// Frees memory allocated by this plugin.
@_cdecl("aro_plugin_free")
public func aroPluginFree(_ ptr: UnsafeMutablePointer<CChar>?) {
    free(ptr)
}

// MARK: - Zip Logic

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

// MARK: - Helpers

/// Build a JSON response string from a dictionary and return as a C string.
private func jsonResponse(_ result: [String: Any]) -> UnsafeMutablePointer<CChar> {
    do {
        let data = try JSONSerialization.data(withJSONObject: result)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return strdup(json)!
    } catch {
        return strdup("{\"error\": \"Failed to encode result\"}")!
    }
}

/// Build an error JSON response and return as a C string.
/// Uses manual character replacement to avoid Foundation bridging issues.
private func errorResponse(_ message: String) -> UnsafeMutablePointer<CChar> {
    var escaped = ""
    escaped.reserveCapacity(message.count)
    for char in message {
        switch char {
        case "\\": escaped += "\\\\"
        case "\"": escaped += "\\\""
        case "\n": escaped += "\\n"
        case "\r": escaped += "\\r"
        case "\t": escaped += "\\t"
        default: escaped.append(char)
        }
    }
    return strdup("{\"error\": \"\(escaped)\"}")!
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
