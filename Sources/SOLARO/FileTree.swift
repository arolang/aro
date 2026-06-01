// ============================================================
// FileTree.swift
// SOLARO — sidebar file tree data model (Phase 5)
// ============================================================
//
// Builds a directory-grouped tree from `ProjectModel`'s flat file
// lists. Files inside `sources/` subdirectories collapse into
// disclosure groups; files at the project root render flat. The
// `openapi.yaml` contract and `.store` seed files are included
// alongside `.aro` sources so the sidebar shows the whole shape
// of the project, not just the code files.
//
// Pure value type — no SwiftUI imports — so it can be unit
// tested without spinning up a view hierarchy.

import Foundation

struct FileTreeNode: Identifiable, Hashable {
    /// Absolute path; doubles as the SwiftUI identity for List
    /// selection bindings.
    let id: String
    /// Display name (the last path component).
    let name: String
    /// The file/directory URL on disk.
    let url: URL
    /// Classification — picks the row icon + tint.
    let kind: Kind
    /// Empty for leaves, populated for directories.
    var children: [FileTreeNode] = []

    enum Kind: String, Hashable {
        case directory
        case aroSource
        case storeFile
        case openapi
        case other
    }

    /// Children optionality for SwiftUI's OutlineGroup — directories
    /// always have a (possibly empty) children list; leaves return
    /// `nil` so the disclosure triangle disappears.
    var outlineChildren: [FileTreeNode]? {
        kind == .directory ? children : nil
    }
}

enum FileTreeBuilder {

    /// Build the sidebar tree from a loaded project model.
    /// Sort order at every level: directories first (alphabetical),
    /// then files (alphabetical). Within the file group, the
    /// canonical contract (`openapi.yaml`) bubbles to the top of
    /// the root because it documents the whole project.
    static func build(model: ProjectModel) -> [FileTreeNode] {
        var allFiles: [(URL, FileTreeNode.Kind)] = []
        for url in model.sourceFiles { allFiles.append((url, .aroSource)) }
        for url in model.storeFiles  { allFiles.append((url, .storeFile)) }
        if let spec = model.openAPISpec { allFiles.append((spec, .openapi)) }

        return groupByPath(files: allFiles, root: model.root.rootPath)
    }

    /// Recursively partition `files` into:
    ///   - leaves whose parent equals `root`, and
    ///   - subdirectory groups whose first relative component is
    ///     the directory name.
    /// Each subdirectory group recurses one level deeper. Trailing
    /// sort keeps directories before files at every level.
    private static func groupByPath(
        files: [(URL, FileTreeNode.Kind)],
        root: URL
    ) -> [FileTreeNode] {
        let rootPath = root.standardizedFileURL.path

        var directLeaves: [FileTreeNode] = []
        var subdirGroups: [String: [(URL, FileTreeNode.Kind)]] = [:]

        for (url, kind) in files {
            let filePath = url.standardizedFileURL.path
            // Strip the root prefix; drop the leading "/".
            guard filePath.hasPrefix(rootPath + "/") else {
                // File outside the root — surface as a leaf at this
                // level so it isn't silently dropped.
                directLeaves.append(FileTreeNode(
                    id: filePath,
                    name: url.lastPathComponent,
                    url: url,
                    kind: kind
                ))
                continue
            }
            let relative = String(filePath.dropFirst(rootPath.count + 1))
            let components = relative.split(separator: "/", omittingEmptySubsequences: true)
            if components.count == 1 {
                directLeaves.append(FileTreeNode(
                    id: filePath,
                    name: String(components[0]),
                    url: url,
                    kind: kind
                ))
            } else {
                let firstDir = String(components[0])
                subdirGroups[firstDir, default: []].append((url, kind))
            }
        }

        var subdirNodes: [FileTreeNode] = []
        for (dirName, subFiles) in subdirGroups {
            let subdirURL = root.appendingPathComponent(dirName)
            let childNodes = groupByPath(files: subFiles, root: subdirURL)
            subdirNodes.append(FileTreeNode(
                id: subdirURL.standardizedFileURL.path,
                name: dirName,
                url: subdirURL,
                kind: .directory,
                children: childNodes
            ))
        }

        // Directories sorted alphabetically; files sorted alphabetically
        // but `openapi.yaml` bubbles to the very top of the file group.
        subdirNodes.sort { $0.name < $1.name }
        directLeaves.sort { lhs, rhs in
            if lhs.kind == .openapi, rhs.kind != .openapi { return true }
            if rhs.kind == .openapi, lhs.kind != .openapi { return false }
            return lhs.name < rhs.name
        }
        return subdirNodes + directLeaves
    }
}
