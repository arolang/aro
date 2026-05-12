// ============================================================
// PathGuard.swift
// AROLM - path normalization/scoping for file/shell tools
// ============================================================

import Foundation

/// Scoping helper used by file and shell tools to ensure every path a model
/// touches stays under the session's working directory.
public struct PathGuard: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Resolve `path` (which may be absolute or relative) against the root
    /// and verify that the result is still inside the root after removing
    /// `..` components.
    public func resolve(_ path: String) throws -> URL {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            url = root.appendingPathComponent(path).standardizedFileURL
        }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let urlPath = url.path
        if urlPath != root.path && !urlPath.hasPrefix(rootPath) {
            throw LMToolError.pathOutsideRoot(path)
        }
        return url
    }
}
