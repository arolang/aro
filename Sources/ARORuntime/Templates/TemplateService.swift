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

    /// Render a template and return the rendered string alongside a map of
    /// variable positions within the output.  Used by the reactive Repaint action.
    /// - Returns: (rendered string, [variableKey: TerminalVarPosition])
    func renderAndTrack(path: String, context: ExecutionContext) async throws -> (String, [String: TerminalVarPosition])
}

extension TemplateService {
    /// Default implementation: render without position tracking
    public func renderAndTrack(path: String, context: ExecutionContext) async throws -> (String, [String: TerminalVarPosition]) {
        let rendered = try await render(path: path, context: context)
        return (rendered, [:])
    }
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

    /// Parse-result cache (thread-safe via dedicated actor)
    private let parseCache = ParseCache()

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

    /// Load and parse a template, using the parse cache to avoid redundant disk reads and parses.
    /// - Embedded/registered templates are cached unconditionally (they never change).
    /// - File-system templates are cached keyed by mtime; re-parsed only when the file changes.
    private func loadAndParse(path: String) async throws -> ParsedTemplate {
        // 1. Compile-time embedded templates (binary mode) — cache unconditionally
        if let embedded = embeddedTemplates, let content = embedded[path] {
            if let cached = await parseCache.get(path: path) {
                return cached.parsed
            }
            let parsed = try parseContent(content, path: path)
            await parseCache.set(path: path, entry: CachedTemplate(parsed: parsed, mtime: nil))
            return parsed
        }

        // 2. Runtime-registered templates (set-once semantics) — cache unconditionally
        if let content = await storage.get(path: path) {
            if let cached = await parseCache.get(path: path) {
                return cached.parsed
            }
            let parsed = try parseContent(content, path: path)
            await parseCache.set(path: path, entry: CachedTemplate(parsed: parsed, mtime: nil))
            return parsed
        }

        // 3. File-system templates — cache with mtime validation
        let fullPath = (templatesDirectory as NSString).appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: fullPath) else {
            throw TemplateError.notFound(path: path)
        }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: fullPath))?[.modificationDate] as? Date
        if let cached = await parseCache.get(path: path), cached.mtime == mtime {
            return cached.parsed
        }

        // Cache miss or file changed — read and re-parse
        let content: String
        do {
            content = try String(contentsOfFile: fullPath, encoding: .utf8)
        } catch {
            throw TemplateError.notFound(path: path)
        }

        let parsed = try parseContent(content, path: path)
        await parseCache.set(path: path, entry: CachedTemplate(parsed: parsed, mtime: mtime))
        return parsed
    }

    /// Parse raw template content, wrapping TemplateParseError into TemplateError.
    private func parseContent(_ content: String, path: String) throws -> ParsedTemplate {
        do {
            return try parser.parse(content, path: path)
        } catch let error as TemplateParseError {
            throw TemplateError.parseError(path: path, message: error.localizedDescription)
        }
    }

    public func render(path: String, context: ExecutionContext) async throws -> String {
        let parsed = try await loadAndParse(path: path)

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

    public func renderAndTrack(path: String, context: ExecutionContext) async throws -> (String, [String: TerminalVarPosition]) {
        let parsed = try await loadAndParse(path: path)

        guard let templateExecutor = executor else {
            throw TemplateError.renderError(path: path, message: "Template executor not configured")
        }

        do {
            return try await templateExecutor.renderAndTrack(template: parsed, context: context, templateService: self)
        } catch let error as TemplateError {
            throw error
        } catch {
            throw TemplateError.renderError(path: path, message: error.localizedDescription)
        }
    }
}

/// Cached parse result with optional mtime for invalidation
private struct CachedTemplate: Sendable {
    let parsed: ParsedTemplate
    /// nil → embedded/registered template; never invalidated.
    /// non-nil → file-system template; invalidated when mtime changes.
    let mtime: Date?
}

/// Thread-safe parsed-template cache
private actor ParseCache {
    private var entries: [String: CachedTemplate] = [:]

    func get(path: String) -> CachedTemplate? {
        entries[path]
    }

    func set(path: String, entry: CachedTemplate) {
        entries[path] = entry
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
