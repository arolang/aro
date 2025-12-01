// ============================================================
// ExtractAction.swift
// ARO Runtime - Extract Action Implementation
// ============================================================

import Foundation
import AROParser

/// Extracts a value from a source object
///
/// The Extract action is a REQUEST action that pulls data from an external
/// or internal source. It supports:
/// - Simple variable extraction: `<Extract> the <user> from the <request>`
/// - Nested property access: `<Extract> the <id> from the <user: profile>`
/// - Array indexing (via specifiers): `<Extract> the <first> from the <items: 0>`
///
/// ## Example
/// ```
/// <Extract> the <user: identifier> from the <incoming-request: parameters>.
/// ```
public struct ExtractAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["extract", "parse", "get"]
    public static let validPrepositions: Set<Preposition> = [.from, .via]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get source object
        guard let source = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // If no specifiers, return the source directly (it's already any Sendable)
        if object.specifiers.isEmpty {
            return source
        }

        // Extract nested value using specifiers as path
        return try extractValue(from: source, path: object.specifiers)
    }

    private func extractValue(from source: any Sendable, path: [String]) throws -> any Sendable {
        var current: any Sendable = source

        for key in path {
            current = try extractProperty(from: current, key: key)
        }

        return current
    }

    private func extractProperty(from source: any Sendable, key: String) throws -> any Sendable {
        // Try dictionary access
        if let dict = source as? [String: any Sendable], let value = dict[key] {
            return value
        }

        // Try string dictionary access
        if let dict = source as? [String: String], let value = dict[key] {
            return value
        }

        // Try array index access
        if let array = source as? [any Sendable], let index = Int(key), index >= 0, index < array.count {
            return array[index]
        }

        // Return original source if key not found but exists
        throw ActionError.propertyNotFound(property: key, on: String(describing: type(of: source)))
    }
}

/// Retrieves data from a repository
public struct RetrieveAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["retrieve", "fetch", "load", "find"]
    public static let validPrepositions: Set<Preposition> = [.from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get repository name
        let repoName = object.base

        // Try to resolve as a variable (repositories are not directly supported yet)
        if let source = context.resolveAny(repoName) {
            return source
        }

        throw ActionError.undefinedRepository(repoName)
    }
}

/// Receives data from an external source (e.g., HTTP request, socket)
public struct ReceiveAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["receive"]
    public static let validPrepositions: Set<Preposition> = [.from, .via]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Receive is typically handled by the event system
        // Here we just resolve the source
        guard let source = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // source is already `any Sendable` from resolveAny
        return source
    }
}

/// Fetches data from an HTTP endpoint
public struct FetchAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["fetch", "call"]
    public static let validPrepositions: Set<Preposition> = [.from, .via]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get HTTP client service
        guard let httpClient = context.service(HTTPClientService.self) else {
            // Fallback to variable resolution
            guard let source = context.resolveAny(object.base) else {
                throw ActionError.undefinedVariable(object.base)
            }
            // source is already `any Sendable` from resolveAny
            return source
        }

        // Get URL from object
        guard let url: String = context.resolve(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Perform HTTP request
        return try await httpClient.get(url: url)
    }
}

/// Reads data from a file
public struct ReadAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["read"]
    public static let validPrepositions: Set<Preposition> = [.from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get file service
        guard let fileService = context.service(FileSystemService.self) else {
            throw ActionError.missingService("FileSystemService")
        }

        // Get file path
        guard let path: String = context.resolve(object.base) else {
            // Use object base as literal path
            return try await fileService.read(path: object.base)
        }

        return try await fileService.read(path: path)
    }
}

// MARK: - Placeholder Services

/// HTTP client service protocol
public protocol HTTPClientService: Sendable {
    func get(url: String) async throws -> any Sendable
    func post(url: String, body: any Sendable) async throws -> any Sendable
}

/// File system service protocol
public protocol FileSystemService: Sendable {
    func read(path: String) async throws -> String
    func write(path: String, content: String) async throws
    func exists(path: String) -> Bool
}
