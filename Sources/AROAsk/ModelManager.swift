// ============================================================
// ModelManager.swift
// AROAsk - downloads and caches models from Hugging Face
// ============================================================

import Foundation
import Crypto

/// Metadata for a model entry in the bundled manifest.
public struct ModelEntry: Codable, Sendable {
    public var modelId: String
    public var primaryFile: String
    public var backend: String
    public var sizeGb: Double?
    public var contextLength: Int?

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case primaryFile = "primary_file"
        case backend
        case sizeGb = "size_gb"
        case contextLength = "context_length"
    }
}

/// Manifest bundled in Resources/model-manifest.json.
public struct ModelManifest: Codable, Sendable {
    public var models: [ModelEntry]
}

/// Downloads, caches and locates Hugging Face models.
public actor ModelManager {
    private let cacheDir: URL
    private let manifest: ModelManifest

    public init() throws {
        // Cache in ~/.cache/aro/ask/ (respects HF_HOME)
        let env = ProcessInfo.processInfo.environment
        let base: URL
        if let hfHome = env["HF_HOME"] {
            base = URL(fileURLWithPath: hfHome)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache")
                .appendingPathComponent("aro")
                .appendingPathComponent("ask")
        }
        self.cacheDir = base
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Load bundled manifest
        if let url = Bundle.module.url(forResource: "model-manifest", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            self.manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        } else {
            self.manifest = ModelManifest(models: [])
        }
    }

    public func entry(for modelId: String) throws -> ModelEntry {
        if let e = manifest.models.first(where: { $0.modelId == modelId }) {
            return e
        }
        // Default entry for unknown models
        return ModelEntry(
            modelId: modelId,
            primaryFile: "config.json",
            backend: "auto",
            sizeGb: nil,
            contextLength: 4096
        )
    }

    public func modelDirectory(for modelId: String) -> URL {
        let sanitized = modelId.replacingOccurrences(of: "/", with: "--")
        return cacheDir.appendingPathComponent(sanitized)
    }

    /// Check if a model is already downloaded.
    public func isInstalled(_ modelId: String) -> Bool {
        let dir = modelDirectory(for: modelId)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path)
    }

    /// Ensure a model is downloaded. Prompts the user via `confirm` before
    /// downloading. Reports progress via `progress`.
    public func ensureInstalled(
        _ modelId: String,
        confirm: @Sendable (Double) async -> Bool,
        progress: @Sendable (String, Int64, Int64?) async -> Void
    ) async throws -> URL {
        let dir = modelDirectory(for: modelId)

        if isInstalled(modelId) {
            return dir
        }

        let entry = try entry(for: modelId)
        let sizeGb = entry.sizeGb ?? 5.0

        guard await confirm(sizeGb) else {
            throw ModelManagerError.userDeclined
        }

        // Download from HuggingFace using the API
        try await downloadModel(modelId: modelId, to: dir, progress: progress)
        return dir
    }

    /// Check for updates by comparing local vs remote commit SHAs.
    public func checkForUpdate(_ modelId: String) async -> UpdateStatus {
        guard isInstalled(modelId) else { return .notInstalled }

        let commitFile = modelDirectory(for: modelId).appendingPathComponent(".commit_sha")
        let localCommit = (try? String(contentsOf: commitFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fetch remote commit
        let url = URL(string: "https://huggingface.co/api/models/\(modelId)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let remoteSha = json["sha"] as? String else {
            return .checkFailed
        }

        if localCommit == remoteSha {
            return .upToDate
        }
        return .updateAvailable(local: localCommit ?? "unknown", remote: remoteSha)
    }

    private func downloadModel(
        modelId: String,
        to dir: URL,
        progress: @Sendable (String, Int64, Int64?) async -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Fetch file list from HuggingFace API
        let listURL = URL(string: "https://huggingface.co/api/models/\(modelId)")!
        var listRequest = URLRequest(url: listURL)
        listRequest.timeoutInterval = 30

        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"] {
            listRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (listData, _) = try await URLSession.shared.data(for: listRequest)
        guard let json = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
              let siblings = json["siblings"] as? [[String: Any]] else {
            throw ModelManagerError.downloadFailed("Could not fetch file list for \(modelId)")
        }

        // Save commit SHA
        if let sha = json["sha"] as? String {
            try Data(sha.utf8).write(to: dir.appendingPathComponent(".commit_sha"))
        }

        let files = siblings.compactMap { $0["rfilename"] as? String }
        for file in files {
            let fileURL = URL(string: "https://huggingface.co/\(modelId)/resolve/main/\(file)")!
            var req = URLRequest(url: fileURL)
            if let token = ProcessInfo.processInfo.environment["HF_TOKEN"] {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, _) = try await URLSession.shared.data(for: req)

            let dest = dir.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: dest)
            await progress(file, Int64(data.count), nil)
        }
    }
}

public enum ModelManagerError: Error, CustomStringConvertible {
    case userDeclined
    case downloadFailed(String)

    public var description: String {
        switch self {
        case .userDeclined: return "User declined model download"
        case .downloadFailed(let msg): return "Model download failed: \(msg)"
        }
    }
}

public enum UpdateStatus: Sendable {
    case upToDate
    case updateAvailable(local: String, remote: String)
    case notInstalled
    case checkFailed
}
