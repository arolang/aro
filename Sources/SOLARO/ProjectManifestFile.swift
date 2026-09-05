// ============================================================
// ProjectManifestFile.swift
// SOLARO — the project manifest as a file type
// ============================================================
//
// An ARO project's manifest is canonically `aro.yaml`. macOS
// Launch Services associates files by TYPE (extension/UTI), never
// by filename, so `aro.yaml` can only ever be an *alternate* YAML
// handler — double-click keeps opening the user's YAML editor
// unless they change a per-file default. `<name>.aroproject` is
// the same file wearing an extension Solaro can OWN: identical
// YAML content, identical meaning, but double-click in Finder
// always opens the project.
//
// Every place that treats `aro.yaml` as the manifest goes through
// this type, so the two spellings cannot drift.

import Foundation

enum ProjectManifestFile {

    /// The dedicated, Finder-associable extension.
    static let dedicatedExtension = "aroproject"

    /// Whether `url` is a project manifest — canonical `aro.yaml`
    /// (or `aro.yml`), or any `<name>.aroproject`.
    static func isManifest(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name == "aro.yaml" || name == "aro.yml"
            || url.pathExtension.lowercased() == dedicatedExtension
    }

    /// The manifest in `directory`, if one exists. The canonical
    /// name wins over the dedicated extension so a project carrying
    /// both reads deterministically.
    static func find(in directory: URL) -> URL? {
        let fm = FileManager.default
        for canonical in ["aro.yaml", "aro.yml"] {
            let candidate = directory.appendingPathComponent(canonical)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return nil }
        return entries
            .filter { $0.pathExtension.lowercased() == dedicatedExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }
}
