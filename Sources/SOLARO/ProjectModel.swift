// ============================================================
// ProjectModel.swift
// SOLARO — project loading and source-file discovery
// ============================================================
//
// Walks the project root once on load and finds every `.aro` file
// in the tree (matches the discovery rules from `CLAUDE.md`:
// all `.aro` files in the root and subdirectories at any depth).
// Reads OpenAPI specs and store files alongside.

import Foundation

/// A SOLARO project loaded from a directory.
///
/// Phase 1 captures the things the shell needs immediately:
/// the source files (for the file tree), an OpenAPI spec if
/// present (for the API Contract node in the Map view —
/// Phase 2+), and the project root.
struct ProjectModel {

    let root: Project

    /// All `.aro` files under `root` (recursive). Paths are absolute.
    let sourceFiles: [URL]

    /// Path to `openapi.yaml` at the project root if it exists.
    let openAPISpec: URL?

    /// `.store` files discovered alongside the sources.
    let storeFiles: [URL]

    /// Diagnostic info that gets surfaced in the status bar.
    let discoveredAt: Date

    /// Discover `.aro` and `.store` files inside `rootPath`.
    ///
    /// Returns an empty `sourceFiles` list (not an error) when the
    /// project has no `.aro` files — the UI handles the empty case
    /// gracefully so the user can see they opened the wrong folder.
    static func load(_ project: Project) throws -> ProjectModel {
        let rootPath = project.rootPath
        var sources: [URL] = []
        var stores: [URL] = []

        let enumerator = FileManager.default.enumerator(
            at: rootPath,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        while let url = enumerator?.nextObject() as? URL {
            switch url.pathExtension {
            case "aro":   sources.append(url)
            case "store": stores.append(url)
            default:      continue
            }
        }
        sources.sort { $0.path < $1.path }
        stores.sort { $0.path < $1.path }

        let openAPICandidate = rootPath.appendingPathComponent("openapi.yaml")
        let openAPI: URL? = FileManager.default.fileExists(atPath: openAPICandidate.path)
            ? openAPICandidate
            : nil

        return ProjectModel(
            root: project,
            sourceFiles: sources,
            openAPISpec: openAPI,
            storeFiles: stores,
            discoveredAt: Date()
        )
    }
}
