// ============================================================
// FileObject.swift
// ARO Runtime - File System Object
// ============================================================

import Foundation

// MARK: - File Object

/// File system object for format-aware file I/O
///
/// A bidirectional dynamic object that reads from and writes to files.
/// The path is provided as a qualifier in ARO syntax.
///
/// Automatically detects format based on file extension and
/// serializes/deserializes accordingly.
///
/// ## ARO Usage
/// ```aro
/// <Read> the <config> from the <file: "./config.yaml">.
/// <Write> <data> to the <file: "./output.json">.
/// ```
///
/// ## Security Note
/// File paths are validated to prevent directory traversal attacks.
/// Paths containing ".." components or absolute paths outside the
/// current working directory are rejected.
public struct FileObject: SystemObject {
    public static let identifier = "file"
    public static let description = "File system I/O with format detection"

    public var capabilities: SystemObjectCapabilities { .bidirectional }

    private let path: String
    private let fileService: FileSystemService

    /// Create a file object for the given path
    ///
    /// - Parameters:
    ///   - path: The file path
    ///   - fileService: The file system service for I/O operations
    /// - Throws: SystemObjectError.invalidPath if path validation fails
    public init(path: String, fileService: FileSystemService) throws {
        // Validate path for security
        try Self.validatePath(path)
        self.path = path
        self.fileService = fileService
    }

    /// Validate file path to prevent directory traversal attacks
    ///
    /// - Parameter path: The file path to validate
    /// - Throws: SystemObjectError.invalidPath if validation fails
    private static func validatePath(_ path: String) throws {
        // Check for path traversal patterns in the original path
        // This catches attempts like "../../../etc/passwd" or "foo/../../bar"
        let components = path.components(separatedBy: "/")

        // Track directory depth to detect if we escape the base directory
        var depth = 0
        for component in components {
            if component == ".." {
                depth -= 1
                // If depth goes negative, we're trying to escape the base directory
                if depth < 0 {
                    throw SystemObjectError.invalidPath(path, reason: "Path traversal not allowed")
                }
            } else if !component.isEmpty && component != "." {
                depth += 1
            }
        }

        // Additional check: normalize and verify no ".." remains
        let url = URL(fileURLWithPath: path)
        let normalizedPath = url.standardized.path

        if normalizedPath.contains("/../") || normalizedPath.hasSuffix("/..") {
            throw SystemObjectError.invalidPath(path, reason: "Path traversal not allowed")
        }
    }

    public func read(property: String?) async throws -> any Sendable {
        let content = try await fileService.read(path: path)

        // Detect format and deserialize
        let format = FileFormat.detect(from: path)

        if format.supportsDeserialization {
            return FormatDeserializer.deserialize(content, format: format)
        } else {
            // Return raw content for non-deserializable formats
            return content
        }
    }

    public func write(_ value: any Sendable) async throws {
        // Detect format and serialize
        let format = FileFormat.detect(from: path)
        // Extract variable name from path for formats that need it (XML, SQL, TOML)
        let variableName = URL(fileURLWithPath: path)
            .deletingPathExtension()
            .lastPathComponent
        let content = FormatSerializer.serialize(value, format: format, variableName: variableName)

        try await fileService.write(path: path, content: content)
    }
}

// MARK: - File Object Factory

/// Factory for creating file objects from execution context
public struct FileObjectFactory {
    /// Create a file object for the given path and context
    ///
    /// - Parameters:
    ///   - path: The file path
    ///   - context: The execution context containing the file service
    /// - Returns: A FileObject if the file service is available
    /// - Throws: SystemObjectError.invalidPath if path validation fails
    public static func create(path: String, context: any ExecutionContext) throws -> FileObject? {
        guard let fileService = context.service(FileSystemService.self) else {
            return nil
        }
        return try FileObject(path: path, fileService: fileService)
    }
}

// MARK: - Registration

public extension SystemObjectRegistry {
    /// Register file-related system objects
    ///
    /// Note: The file object is dynamic and created with a path parameter,
    /// so we register a factory that extracts the path from the qualifier.
    func registerFileObjects() {
        // File object needs special handling because it requires a path parameter
        // The registration here is a placeholder - actual instantiation happens
        // when the action executor resolves the object with its qualifier
        register(
            "file",
            description: FileObject.description,
            capabilities: .bidirectional
        ) { context in
            // Default file object - actual path comes from qualifier
            // This is a fallback for when no path is specified
            PlaceholderFileObject()
        }
    }
}

// MARK: - Placeholder for Registration

/// Placeholder file object used when no path is specified
private struct PlaceholderFileObject: SystemObject {
    static let identifier = "file"
    static let description = "File requires a path qualifier"

    var capabilities: SystemObjectCapabilities { .bidirectional }

    func read(property: String?) async throws -> any Sendable {
        throw SystemObjectError.propertyNotFound("path", in: Self.identifier)
    }

    func write(_ value: any Sendable) async throws {
        throw SystemObjectError.propertyNotFound("path", in: Self.identifier)
    }
}
