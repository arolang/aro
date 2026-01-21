// ============================================================
// FileActions.swift
// ARO Runtime - File and Directory Action Implementations
// ARO-0036: Native File and Directory Operations
// ============================================================

import Foundation
import AROParser

// MARK: - List Action

/// Lists directory contents with optional pattern matching
///
/// ## Example
/// ```
/// <List> the <entries> from the <directory: path>.
/// <List> the <aro-files> from the <directory: src-path> matching "*.aro".
/// <List> the <all-files> from the <directory: project-path> recursively.
/// ```
public struct ListAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["list"]
    public static let validPrepositions: Set<Preposition> = [.from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get directory path from specifiers or base
        let directoryPath: String
        if let specifier = object.specifiers.first, let path: String = context.resolve(specifier) {
            directoryPath = path
        } else if let path: String = context.resolve(object.base) {
            directoryPath = path
        } else if object.base != "directory" {
            directoryPath = object.base
        } else if let specifier = object.specifiers.first {
            directoryPath = specifier
        } else {
            throw ActionError.runtimeError("List requires a directory path")
        }

        // Check for pattern in specifiers (e.g., matching "*.aro")
        let pattern = result.specifiers.first { $0.contains("*") || $0.contains("?") }

        // Check for recursive flag
        let recursive = result.specifiers.contains("recursively") ||
                       object.specifiers.contains("recursively")

        // Get file service
        guard let fileService = context.service(FileSystemService.self) else {
            throw ActionError.missingService("FileSystemService")
        }

        // List directory
        let entries = try await fileService.list(
            directory: directoryPath,
            pattern: pattern,
            recursive: recursive
        )

        // Convert to array of dictionaries for ARO context
        let entriesArray: [[String: any Sendable]] = entries.map { $0.toDictionary() }

        // Note: We don't rebind the result variable here to maintain immutability
        // The return value is handled by the runtime

        return entriesArray
    }
}

// MARK: - Stat Action

/// Gets detailed metadata for a file or directory
///
/// ## Example
/// ```
/// <Stat> the <info> for the <file: "./document.pdf">.
/// <Stat> the <dir-info> for the <directory: "./src">.
/// ```
public struct StatAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["stat"]
    public static let validPrepositions: Set<Preposition> = [.for]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get path from specifiers or base
        let path: String
        if let specifier = object.specifiers.first, let resolvedPath: String = context.resolve(specifier) {
            path = resolvedPath
        } else if let resolvedPath: String = context.resolve(object.base) {
            path = resolvedPath
        } else if object.base != "file" && object.base != "directory" {
            path = object.base
        } else if let specifier = object.specifiers.first {
            path = specifier
        } else {
            throw ActionError.runtimeError("Stat requires a file or directory path")
        }

        // Get file service
        guard let fileService = context.service(FileSystemService.self) else {
            throw ActionError.missingService("FileSystemService")
        }

        // Get stats
        let info = try await fileService.stat(path: path)

        // Convert to dictionary for ARO context
        let infoDict = info.toDictionary()

        // Note: We don't rebind the result variable here to maintain immutability
        // The return value is handled by the runtime

        return infoDict
    }
}

// MARK: - Exists Action

/// Checks if a file or directory exists
///
/// ## Example
/// ```
/// <Exists> the <found> for the <file: "./config.json">.
/// <Exists> the <dir-exists> for the <directory: "./output">.
/// ```
public struct ExistsAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["exists"]
    public static let validPrepositions: Set<Preposition> = [.for]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get path from specifiers or base
        let path: String
        if let specifier = object.specifiers.first, let resolvedPath: String = context.resolve(specifier) {
            path = resolvedPath
        } else if let resolvedPath: String = context.resolve(object.base) {
            path = resolvedPath
        } else if object.base != "file" && object.base != "directory" {
            path = object.base
        } else if let specifier = object.specifiers.first {
            path = specifier
        } else {
            throw ActionError.runtimeError("Exists requires a file or directory path")
        }

        // Get file service
        guard let fileService = context.service(FileSystemService.self) else {
            throw ActionError.missingService("FileSystemService")
        }

        // Check if expecting specific type
        let expectsFile = object.base == "file"
        let expectsDirectory = object.base == "directory"

        // Check existence with type
        let (exists, isDirectory) = fileService.existsWithType(path: path)

        // Validate type if specified
        let resultValue: Bool
        if exists {
            if expectsFile && isDirectory {
                resultValue = false  // Expected file but found directory
            } else if expectsDirectory && !isDirectory {
                resultValue = false  // Expected directory but found file
            } else {
                resultValue = true
            }
        } else {
            resultValue = false
        }

        // Bind result
        context.bind(result.base, value: resultValue)

        return resultValue
    }
}

// MARK: - Make Action

/// Creates a file or directory at the specified path
///
/// ## Example
/// ```
/// <Make> the <directory> at the <path: "./output/reports/2024">.
/// <Touch> the <file> at the <path: "./output/log.txt">.
/// <CreateDirectory> the <output-dir> to the <path: "./output">.
/// ```
///
/// ## Verbs
/// - `make` (canonical)
/// - `touch` (synonym)
/// - `createdirectory` (synonym)
/// - `mkdir` (synonym)
public struct MakeAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["make", "touch", "createdirectory", "mkdir"]
    public static let validPrepositions: Set<Preposition> = [.to, .for, .at]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get path from specifiers or base
        let path: String
        if let specifier = object.specifiers.first, let resolvedPath: String = context.resolve(specifier) {
            path = resolvedPath
        } else if let resolvedPath: String = context.resolve(object.base) {
            path = resolvedPath
        } else if object.base != "path" {
            path = object.base
        } else if let specifier = object.specifiers.first {
            path = specifier
        } else {
            throw ActionError.runtimeError("Make requires a path")
        }

        // Get file service
        guard let fileService = context.service(FileSystemService.self) else {
            throw ActionError.missingService("FileSystemService")
        }

        // Determine if creating file or directory based on result.base
        let isFile = result.base == "file"

        if isFile {
            // Touch creates or updates a file
            try await fileService.touch(path: path)
        } else {
            // Create directory (default behavior)
            try await fileService.createDirectory(path: path)
        }

        // Note: We don't rebind the result variable here to maintain immutability
        // The return value is handled by the runtime
        let resultValue = MakeResult(path: path, success: true, isFile: isFile)

        return resultValue
    }
}

/// Result of a make operation (file or directory creation)
public struct MakeResult: Sendable, Equatable {
    public let path: String
    public let success: Bool
    public let isFile: Bool
}

// MARK: - Copy Action

/// Copies files or directories
///
/// ## Example
/// ```
/// <Copy> the <file: "./template.txt"> to the <destination: "./copy.txt">.
/// <Copy> the <directory: "./src"> to the <destination: "./backup/src">.
/// ```
public struct CopyAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["copy"]
    public static let validPrepositions: Set<Preposition> = [.to]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get source path from result specifiers
        let sourcePath: String
        if let specifier = result.specifiers.first, let path: String = context.resolve(specifier) {
            sourcePath = path
        } else if let path: String = context.resolve(result.base) {
            sourcePath = path
        } else if result.base != "file" && result.base != "directory" {
            sourcePath = result.base
        } else if let specifier = result.specifiers.first {
            sourcePath = specifier
        } else {
            throw ActionError.runtimeError("Copy requires a source path")
        }

        // Get destination path from object specifiers
        let destPath: String
        if let specifier = object.specifiers.first, let path: String = context.resolve(specifier) {
            destPath = path
        } else if let path: String = context.resolve(object.base) {
            destPath = path
        } else if object.base != "destination" {
            destPath = object.base
        } else if let specifier = object.specifiers.first {
            destPath = specifier
        } else {
            throw ActionError.runtimeError("Copy requires a destination path")
        }

        // Get file service
        guard let fileService = context.service(FileSystemService.self) else {
            throw ActionError.missingService("FileSystemService")
        }

        // Copy file or directory
        try await fileService.copy(source: sourcePath, destination: destPath)

        return CopyResult(source: sourcePath, destination: destPath, success: true)
    }
}

/// Result of a copy operation
public struct CopyResult: Sendable, Equatable {
    public let source: String
    public let destination: String
    public let success: Bool
}

// MARK: - Move Action

/// Moves or renames files and directories
///
/// ## Example
/// ```
/// <Move> the <file: "./draft.txt"> to the <destination: "./final.txt">.
/// <Move> the <directory: "./temp"> to the <destination: "./processed">.
/// ```
public struct MoveAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["move", "rename"]
    public static let validPrepositions: Set<Preposition> = [.to]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get source path from result specifiers
        let sourcePath: String
        if let specifier = result.specifiers.first, let path: String = context.resolve(specifier) {
            sourcePath = path
        } else if let path: String = context.resolve(result.base) {
            sourcePath = path
        } else if result.base != "file" && result.base != "directory" {
            sourcePath = result.base
        } else if let specifier = result.specifiers.first {
            sourcePath = specifier
        } else {
            throw ActionError.runtimeError("Move requires a source path")
        }

        // Get destination path from object specifiers
        let destPath: String
        if let specifier = object.specifiers.first, let path: String = context.resolve(specifier) {
            destPath = path
        } else if let path: String = context.resolve(object.base) {
            destPath = path
        } else if object.base != "destination" {
            destPath = object.base
        } else if let specifier = object.specifiers.first {
            destPath = specifier
        } else {
            throw ActionError.runtimeError("Move requires a destination path")
        }

        // Get file service
        guard let fileService = context.service(FileSystemService.self) else {
            throw ActionError.missingService("FileSystemService")
        }

        // Move file or directory
        try await fileService.move(source: sourcePath, destination: destPath)

        return MoveResult(source: sourcePath, destination: destPath, success: true)
    }
}

/// Result of a move operation
public struct MoveResult: Sendable, Equatable {
    public let source: String
    public let destination: String
    public let success: Bool
}

// MARK: - Append Action

/// Appends data to a file
///
/// ## Example
/// ```
/// <Append> the <log-line> to the <file: "./logs/app.log">.
/// <Append> the <entry> to the <file: "./data.txt"> with "\nNew line".
/// ```
public struct AppendAction: ActionImplementation {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["append"]
    public static let validPrepositions: Set<Preposition> = [.to, .into]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get content to append
        // Priority: with clause literal, result variable, result base
        let content: String
        if let literal = context.resolveAny("_literal_") {
            if let str = literal as? String {
                content = str
            } else {
                content = String(describing: literal)
            }
        } else if let expr = context.resolveAny("_expression_") {
            if let str = expr as? String {
                content = str
            } else {
                content = String(describing: expr)
            }
        } else if let value: String = context.resolve(result.base) {
            content = value
        } else if let value = context.resolveAny(result.base) {
            content = String(describing: value)
        } else {
            content = ""
        }

        // Get file path from specifiers or base
        let path: String
        if let specifier = object.specifiers.first, let resolvedPath: String = context.resolve(specifier) {
            path = resolvedPath
        } else if let resolvedPath: String = context.resolve(object.base) {
            path = resolvedPath
        } else if object.base != "file" {
            path = object.base
        } else if let specifier = object.specifiers.first {
            path = specifier
        } else {
            throw ActionError.runtimeError("Append requires a file path")
        }

        // Get file service
        guard let fileService = context.service(FileSystemService.self) else {
            throw ActionError.missingService("FileSystemService")
        }

        // Append to file
        try await fileService.append(path: path, content: content)

        return AppendResult(path: path, success: true)
    }
}

/// Result of an append operation
public struct AppendResult: Sendable, Equatable {
    public let path: String
    public let success: Bool
}
