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
import AROPluginSDK

// MARK: - Plugin Registration

private let plugin = AROPlugin(name: "ZipPlugin", version: "1.0.0", handle: "Zip")
    .service("zip", methods: ["compress", "decompress", "list"]) { method, input in
        let args = input.with

        do {
            let result = try executeMethod(method, args: args)
            return .success(result)
        } catch {
            return .failure(.executionFailed, String(describing: error))
        }
    }

private let _registration: Void = { AROPluginExport.register(plugin) }()

// MARK: - Zip Logic

/// Execute a zip method
private func executeMethod(_ method: String, args: Params) throws -> [String: Any] {
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
private func compress(args: Params) throws -> [String: Any] {
    guard let rawFiles = args.array("files") else {
        throw ZipPluginError.missingArgument("files")
    }
    let files = rawFiles.compactMap { $0 as? String }

    guard let outputPath = args.string("output") else {
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
private func decompress(args: Params) throws -> [String: Any] {
    guard let archivePath = args.string("archive") else {
        throw ZipPluginError.missingArgument("archive")
    }

    let destination = args.string("destination") ?? "."

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
private func listContents(args: Params) throws -> [String: Any] {
    guard let archivePath = args.string("archive") else {
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
            if fullPath.hasPrefix(prefixToRemove) {
                files.append(String(fullPath.dropFirst(prefixToRemove.count)))
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
