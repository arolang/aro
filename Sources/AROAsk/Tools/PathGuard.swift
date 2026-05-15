// ============================================================
// PathGuard.swift
// AROAsk - restricts file/shell operations to working directory
// ============================================================

import Foundation

/// Resolves relative paths and ensures they stay within the root.
public struct PathGuard: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Resolve a relative path against root. Throws if the result escapes.
    public func resolve(_ relativePath: String) throws -> URL {
        let resolved: URL
        if relativePath.hasPrefix("/") {
            resolved = URL(fileURLWithPath: relativePath).standardizedFileURL
        } else {
            resolved = root.appendingPathComponent(relativePath).standardizedFileURL
        }
        guard resolved.path.hasPrefix(root.path) else {
            throw AskToolError.pathOutsideRoot(relativePath)
        }
        return resolved
    }
}
