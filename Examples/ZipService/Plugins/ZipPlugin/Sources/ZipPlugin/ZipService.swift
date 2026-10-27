// ============================================================
// ZipService.swift
// ARO Plugin - Zip file compression using weichsel/ZIPFoundation
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
import ZIPFoundation
import AROPluginKit

// MARK: - Plugin Registration

@AROExport
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

    // Create zip archive. `.create` wants a path with nothing at it, so an
    // archive from a previous run is replaced rather than appended to.
    if FileManager.default.fileExists(atPath: outputURL.path) {
        try FileManager.default.removeItem(at: outputURL)
    }
    let archive = try Archive(url: outputURL, accessMode: .create)
    for fileURL in fileURLs {
        try archive.addEntry(
            with: fileURL.lastPathComponent,
            fileURL: fileURL,
            compressionMethod: .deflate
        )
    }

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
    try FileManager.default.createDirectory(
        at: destinationURL, withIntermediateDirectories: true
    )
    try FileManager.default.unzipItem(at: archiveURL, to: destinationURL)

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

    // Read the central directory. Listing an archive does not need it
    // extracted, so nothing is written anywhere.
    let archive = try Archive(url: archiveURL, accessMode: .read)
    let files = archive.map { $0.path }

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
