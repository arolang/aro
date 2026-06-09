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
        /// Project manifest — `aro.yaml` next to `main.aro`. Marks
        /// the project root and carries the entrypoint / name /
        /// version metadata. Gets its own icon + tint so the file
        /// tree reads it as configuration, not source.
        case projectManifest
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
        // `aro.yaml` at the root is the project manifest. The
        // model doesn't track it explicitly, so check the disk
        // and inject the entry when present.
        let manifest = model.root.rootPath
            .appendingPathComponent("aro.yaml")
        if FileManager.default.fileExists(atPath: manifest.path) {
            allFiles.append((manifest, .projectManifest))
        }

        return groupByPath(files: allFiles, root: model.root.rootPath)
    }

    /// Directory entries the "All files" view never surfaces.
    /// Mostly toolchain output and SCM state — keeping the sidebar
    /// useful instead of drowning the user in `.build/` and `.git/`.
    private static let ignoredDirs: Set<String> = [
        ".build", ".git", ".solaro", ".swiftpm", "node_modules",
        ".idea", ".vscode", "DerivedData"
    ]

    /// Walk the project root on disk and return every file/directory
    /// (sans the well-known noise set). Used when the user flips the
    /// sidebar Files tab into "All files" mode. Known ARO file types
    /// (`*.aro`, `*.store`, `openapi.yaml`) still get their tinted
    /// icons; everything else is `.other`.
    static func buildAll(model: ProjectModel) -> [FileTreeNode] {
        return scanDirectory(model.root.rootPath, model: model)
    }

    private static func scanDirectory(
        _ dir: URL,
        model: ProjectModel
    ) -> [FileTreeNode] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var directories: [FileTreeNode] = []
        var files: [FileTreeNode] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") { continue }   // hidden — skip
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey])
                .isDirectory) == true
            if isDir {
                if ignoredDirs.contains(name) { continue }
                let children = scanDirectory(entry, model: model)
                directories.append(FileTreeNode(
                    id: entry.standardizedFileURL.path,
                    name: name,
                    url: entry,
                    kind: .directory,
                    children: children
                ))
            } else {
                files.append(FileTreeNode(
                    id: entry.standardizedFileURL.path,
                    name: name,
                    url: entry,
                    kind: classify(entry, model: model)
                ))
            }
        }
        directories.sort { $0.name < $1.name }
        files.sort { lhs, rhs in
            // Project manifest bubbles to the very top, then the
            // OpenAPI contract, then everything else alphabetical.
            // Both files are "project shape" — the user usually
            // glances at them first.
            if lhs.kind == .projectManifest, rhs.kind != .projectManifest { return true }
            if rhs.kind == .projectManifest, lhs.kind != .projectManifest { return false }
            if lhs.kind == .projectManifest, rhs.kind != .projectManifest { return true }
            if rhs.kind == .projectManifest, lhs.kind != .projectManifest { return false }
            if lhs.kind == .openapi, rhs.kind != .openapi { return true }
            if rhs.kind == .openapi, lhs.kind != .openapi { return false }
            return lhs.name < rhs.name
        }
        return directories + files
    }

    /// Map a URL to a `FileTreeNode.Kind` using the project model's
    /// known file lists so `.aro`, `.store`, and `openapi.yaml` keep
    /// their tinted icons in "All files" mode.
    private static func classify(
        _ url: URL,
        model: ProjectModel
    ) -> FileTreeNode.Kind {
        let path = url.standardizedFileURL.path
        if model.sourceFiles.contains(where: { $0.standardizedFileURL.path == path }) {
            return .aroSource
        }
        if model.storeFiles.contains(where: { $0.standardizedFileURL.path == path }) {
            return .storeFile
        }
        if let spec = model.openAPISpec,
           spec.standardizedFileURL.path == path {
            return .openapi
        }
        // `aro.yaml` at the project root is the project manifest.
        if url.lastPathComponent == "aro.yaml" {
            return .projectManifest
        }
        // Catch ARO files outside the discovered set (e.g. an .aro
        // file in a subdirectory not currently treated as a source
        // root) so they still render as code, not generic `other`.
        if url.pathExtension.lowercased() == "aro" {
            return .aroSource
        }
        return .other
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
            if lhs.kind == .projectManifest, rhs.kind != .projectManifest { return true }
            if rhs.kind == .projectManifest, lhs.kind != .projectManifest { return false }
            if lhs.kind == .openapi, rhs.kind != .openapi { return true }
            if rhs.kind == .openapi, lhs.kind != .openapi { return false }
            return lhs.name < rhs.name
        }
        return subdirNodes + directLeaves
    }
}
