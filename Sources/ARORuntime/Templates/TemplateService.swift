// ============================================================
// TemplateService.swift
// ARO Runtime - Template Service (ARO-0050)
// ============================================================

import Foundation

/// Protocol for template loading and rendering services
public protocol TemplateService: Sendable {
    /// Load a template by path
    /// - Parameter path: The template path relative to templates/ directory
    /// - Returns: The raw template content
    /// - Throws: TemplateError if template cannot be loaded
    func load(path: String) async throws -> String

    /// Check if a template exists
    /// - Parameter path: The template path relative to templates/ directory
    /// - Returns: true if the template exists
    func exists(path: String) async -> Bool

    /// Render a template with the given context
    /// - Parameters:
    ///   - path: The template path relative to templates/ directory
    ///   - context: The execution context with variables
    /// - Returns: The rendered template content
    /// - Throws: TemplateError if rendering fails
    func render(path: String, context: ExecutionContext) async throws -> String
}

/// Errors that can occur during template operations
public enum TemplateError: Error, LocalizedError {
    case notFound(path: String)
    case parseError(path: String, message: String)
    case renderError(path: String, message: String)
    case invalidPath(path: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "Template not found: ./templates/\(path)"
        case .parseError(let path, let message):
            return "Template parse error in \(path): \(message)"
        case .renderError(let path, let message):
            return "Template render error in \(path): \(message)"
        case .invalidPath(let path):
            return "Invalid template path: \(path)"
        }
    }
}

/// Default template service implementation
/// Loads templates from the file system with support for embedded templates
public final class AROTemplateService: TemplateService, @unchecked Sendable {
    /// Base directory for templates (typically ./templates/)
    private let templatesDirectory: String

    /// Embedded templates storage (thread-safe via dedicated actor)
    private let storage = TemplateStorage()

    /// Template parser
    private let parser = TemplateParser()

    /// Template executor (set after initialization)
    private var _executor: TemplateExecutor?

    /// Lock for executor access (only used in synchronous contexts)
    private let executorLock = NSLock()

    /// Initialize with a templates directory
    /// - Parameter templatesDirectory: The absolute path to the templates directory
    public init(templatesDirectory: String) {
        self.templatesDirectory = templatesDirectory
    }

    /// Set the template executor (called after initialization to avoid circular dependency)
    public func setExecutor(_ executor: TemplateExecutor) {
        executorLock.lock()
        defer { executorLock.unlock() }
        self._executor = executor
    }

    /// Get the executor (synchronous, safe to call from non-async context)
    private var executor: TemplateExecutor? {
        executorLock.lock()
        defer { executorLock.unlock() }
        return _executor
    }

    /// Register an embedded template (for compiled binary mode)
    /// - Parameters:
    ///   - path: The template path
    ///   - content: The template content
    public func registerEmbeddedTemplate(path: String, content: String) {
        Task {
            await storage.set(path: path, content: content)
        }
    }

    /// Register multiple embedded templates
    /// - Parameter templates: Dictionary of path to content
    public func registerEmbeddedTemplates(_ templates: [String: String]) {
        Task {
            for (path, content) in templates {
                await storage.set(path: path, content: content)
            }
        }
    }

    public func load(path: String) async throws -> String {
        // Validate path (prevent directory traversal)
        guard !path.contains("..") else {
            throw TemplateError.invalidPath(path: path)
        }

        // Check compile-time embedded templates first (ARO-0050 binary mode)
        if let embedded = embeddedTemplates, let content = embedded[path] {
            return content
        }

        // Check runtime registered templates (for interpreter or dynamic registration)
        if let content = await storage.get(path: path) {
            return content
        }

        // Fall back to file system
        let fullPath = (templatesDirectory as NSString).appendingPathComponent(path)

        guard FileManager.default.fileExists(atPath: fullPath) else {
            throw TemplateError.notFound(path: path)
        }

        do {
            return try String(contentsOfFile: fullPath, encoding: .utf8)
        } catch {
            throw TemplateError.notFound(path: path)
        }
    }

    public func exists(path: String) async -> Bool {
        // Check path validity
        guard !path.contains("..") else {
            return false
        }

        // Check compile-time embedded templates first (ARO-0050 binary mode)
        if let embedded = embeddedTemplates, embedded[path] != nil {
            return true
        }

        // Check runtime registered templates
        if await storage.has(path: path) {
            return true
        }

        // Check file system
        let fullPath = (templatesDirectory as NSString).appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: fullPath)
    }

    public func render(path: String, context: ExecutionContext) async throws -> String {
        // Load template content
        let content = try await load(path: path)

        // Parse template
        let parsed: ParsedTemplate
        do {
            parsed = try parser.parse(content, path: path)
        } catch let error as TemplateParseError {
            throw TemplateError.parseError(path: path, message: error.localizedDescription)
        }

        // Get executor
        guard let templateExecutor = executor else {
            throw TemplateError.renderError(path: path, message: "Template executor not configured")
        }

        // Render with executor
        do {
            return try await templateExecutor.render(template: parsed, context: context, templateService: self)
        } catch let error as TemplateError {
            throw error
        } catch {
            throw TemplateError.renderError(path: path, message: error.localizedDescription)
        }
    }
}

/// Thread-safe storage for embedded templates
private actor TemplateStorage {
    private var templates: [String: String] = [:]

    func get(path: String) -> String? {
        templates[path]
    }

    func set(path: String, content: String) {
        templates[path] = content
    }

    func has(path: String) -> Bool {
        templates[path] != nil
    }
}
