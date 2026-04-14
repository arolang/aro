// ============================================================
// ModelManager.swift
// AROLM - download + cache Hugging Face models
// ============================================================

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Per-model descriptor loaded from the bundled `model-manifest.json`.
public struct ModelManifestEntry: Codable, Sendable {
    public let repo: String
    public let backend: String
    public let approximateSizeGb: Double
    public let files: [String]
    public let primaryFile: String
    public let contextLength: Int?
    public let defaultTemperature: Double?
    public let embeddingDim: Int?

    enum CodingKeys: String, CodingKey {
        case repo
        case backend
        case approximateSizeGb = "approximate_size_gb"
        case files
        case primaryFile = "primary_file"
        case contextLength = "context_length"
        case defaultTemperature = "default_temperature"
        case embeddingDim = "embedding_dim"
    }
}

public struct ModelManifest: Codable, Sendable {
    public let models: [String: ModelManifestEntry]
}

public enum ModelManagerError: Error, CustomStringConvertible {
    case manifestMissing
    case unknownModel(String)
    case downloadFailed(String, Int)
    case downloadRefused
    case invalidResponse

    public var description: String {
        switch self {
        case .manifestMissing:
            return "Bundled model-manifest.json could not be loaded"
        case .unknownModel(let name):
            return "Unknown model '\(name)' — not present in manifest"
        case .downloadFailed(let url, let status):
            return "Download failed for \(url) (HTTP \(status))"
        case .downloadRefused:
            return "Model download refused by user"
        case .invalidResponse:
            return "Invalid response from Hugging Face"
        }
    }
}

/// Manages on-disk caching and downloading of models from Hugging Face.
///
/// Default cache root: `~/.cache/aro/models/<repo>/`. Honours `HF_HOME` and
/// `HF_TOKEN` environment variables.
public actor ModelManager {
    public let cacheRoot: URL
    public let manifest: ModelManifest
    private let urlSession: URLSession

    public init(cacheRoot: URL? = nil, urlSession: URLSession = .shared) throws {
        self.urlSession = urlSession
        self.cacheRoot = cacheRoot ?? Self.defaultCacheRoot()
        self.manifest = try Self.loadManifest()
    }

    public static func defaultCacheRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let hfHome = env["HF_HOME"], !hfHome.isEmpty {
            return URL(fileURLWithPath: hfHome).appendingPathComponent("models")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".cache")
            .appendingPathComponent("aro")
            .appendingPathComponent("models")
    }

    private static func loadManifest() throws -> ModelManifest {
        guard let url = Bundle.module.url(forResource: "model-manifest", withExtension: "json") else {
            throw ModelManagerError.manifestMissing
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ModelManifest.self, from: data)
    }

    public func entry(for model: String) throws -> ModelManifestEntry {
        guard let entry = manifest.models[model] else {
            throw ModelManagerError.unknownModel(model)
        }
        return entry
    }

    /// Returns the directory the model is (or would be) stored in.
    public func modelDirectory(for model: String) -> URL {
        cacheRoot.appendingPathComponent(model)
    }

    /// True if every file listed in the manifest is already present on disk.
    public func isInstalled(_ model: String) throws -> Bool {
        let entry = try entry(for: model)
        let dir = modelDirectory(for: model)
        for file in entry.files {
            let path = dir.appendingPathComponent(file).path
            if !FileManager.default.fileExists(atPath: path) {
                return false
            }
        }
        return true
    }

    /// Ensure the given model is cached locally. If not and `confirm` returns
    /// true, the files are streamed from Hugging Face.
    ///
    /// `progress` is called with `(bytes, totalOrNil)` periodically during the
    /// download and is free to ignore updates.
    public func ensureInstalled(
        _ model: String,
        confirm: @Sendable (_ sizeGb: Double) async -> Bool,
        progress: @Sendable (_ file: String, _ received: Int64, _ total: Int64?) -> Void = { _, _, _ in }
    ) async throws -> URL {
        let entry = try entry(for: model)
        let dir = modelDirectory(for: model)
        if try isInstalled(model) {
            return dir
        }

        let ok = await confirm(entry.approximateSizeGb)
        if !ok {
            throw ModelManagerError.downloadRefused
        }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for file in entry.files {
            let target = dir.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: target.path) { continue }
            let urlString = "https://huggingface.co/\(entry.repo)/resolve/main/\(file)"
            guard let url = URL(string: urlString) else {
                throw ModelManagerError.invalidResponse
            }
            try await download(url: url, to: target, file: file, progress: progress)
        }
        return dir
    }

    private func download(
        url: URL,
        to destination: URL,
        file: String,
        progress: @Sendable (String, Int64, Int64?) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelManagerError.invalidResponse
        }
        if http.statusCode < 200 || http.statusCode >= 300 {
            throw ModelManagerError.downloadFailed(url.absoluteString, http.statusCode)
        }
        let total = Int64(data.count)
        progress(file, total, total)

        let tmp = destination.appendingPathExtension("part")
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tmp, to: destination)
    }
}
