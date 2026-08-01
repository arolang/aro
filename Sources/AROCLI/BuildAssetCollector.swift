// ============================================================
// BuildAssetCollector.swift
// ARO CLI - Embeddable asset collection for native builds
// ============================================================
//
// Extracted from BuildCommand (#354): gathering the non-code assets that get
// baked into the binary — the OpenAPI contract and the `templates/` tree — used
// to sit inline in `BuildCommand.run()` as two file-management blocks. Moving it
// here keeps the command a thin coordinator and isolates the JSON-serialization
// and directory-walking concerns.
//
// Behaviour is intentionally identical to the previous inline version: same
// serialization, same verbose messages, same "warn and continue without
// embedding" fallback so the runtime falls back to file-based loading.

import Foundation
import ARORuntime

/// Collects the assets a native build embeds into the produced binary.
enum BuildAssetCollector {

    /// Serialize the discovered OpenAPI spec to JSON for embedding.
    /// Returns `nil` when there is no spec, or when serialization fails
    /// (the runtime then falls back to file-based loading).
    static func openAPISpecJSON(from spec: OpenAPISpec?, verbose: Bool) -> String? {
        guard let spec else { return nil }
        do {
            let encoder = JSONEncoder()
            let jsonData = try encoder.encode(spec)
            if verbose {
                print("  Embedding OpenAPI spec (\(jsonData.count) bytes)")
            }
            return String(data: jsonData, encoding: .utf8)
        } catch {
            print("Warning: Could not serialize OpenAPI spec: \(error)")
            // Continue without embedding - fall back to file-based loading at runtime
            return nil
        }
    }

    /// Discover and serialize the `templates/` tree (ARO-0050) under `rootPath`
    /// into a `{ relativePath: content }` JSON map for embedding. Returns `nil`
    /// when there is no `templates/` directory, it is empty, or serialization
    /// fails (the runtime then falls back to file-based loading).
    static func templatesJSON(rootPath: URL, verbose: Bool) -> String? {
        let templatesDir = rootPath.appendingPathComponent("templates")
        guard FileManager.default.fileExists(atPath: templatesDir.path) else { return nil }
        do {
            var templates: [String: String] = [:]
            let enumerator = FileManager.default.enumerator(at: templatesDir, includingPropertiesForKeys: nil)
            while let fileURL = enumerator?.nextObject() as? URL {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
                if !isDirectory.boolValue {
                    // Get relative path from templates directory
                    let relativePath = fileURL.path.replacingOccurrences(
                        of: templatesDir.path + "/",
                        with: ""
                    )
                    let content = try String(contentsOf: fileURL, encoding: .utf8)
                    templates[relativePath] = content
                }
            }
            guard !templates.isEmpty else { return nil }
            let jsonData = try JSONSerialization.data(withJSONObject: templates)
            if verbose {
                print("  Embedding \(templates.count) template(s) (\(jsonData.count) bytes)")
            }
            return String(data: jsonData, encoding: .utf8)
        } catch {
            print("Warning: Could not serialize templates: \(error)")
            // Continue without embedding - fall back to file-based loading at runtime
            return nil
        }
    }
}
