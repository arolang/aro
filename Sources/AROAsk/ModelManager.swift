// ============================================================
// ModelManager.swift
// AROAsk - downloads and caches models from Hugging Face
// ============================================================

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto

/// Metadata for a model entry in the bundled manifest.
public struct ModelEntry: Codable, Sendable {
    public var modelId: String
    public var primaryFile: String
    public var backend: String
    public var contextLength: Int?

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case primaryFile = "primary_file"
        case backend
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
        progress: @Sendable (DownloadProgress) async -> Void
    ) async throws -> URL {
        let dir = modelDirectory(for: modelId)

        if isInstalled(modelId) {
            return dir
        }

        // Fetch real size from HuggingFace API
        let sizeGb = await fetchModelSize(modelId)

        guard await confirm(sizeGb) else {
            throw ModelManagerError.userDeclined
        }

        // Download from HuggingFace using the API
        try await downloadModel(modelId: modelId, to: dir, progress: progress)
        return dir
    }

    /// Query the HuggingFace API for the total size of a model's files.
    private func fetchModelSize(_ modelId: String) async -> Double {
        let url = URL(string: "https://huggingface.co/api/models/\(modelId)?blobs=true")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"] {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = json["siblings"] as? [[String: Any]] else {
            return 0  // unknown — will show "unknown size"
        }
        let totalBytes: Int64 = siblings.reduce(0) { sum, entry in
            sum + ((entry["size"] as? Int64) ?? (entry["size"] as? Int).map(Int64.init) ?? 0)
        }
        return Double(totalBytes) / 1_000_000_000
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
        progress: @Sendable (DownloadProgress) async -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Fetch file list with sizes from HuggingFace API
        let listURL = URL(string: "https://huggingface.co/api/models/\(modelId)?blobs=true")!
        var listRequest = URLRequest(url: listURL)
        listRequest.timeoutInterval = 30

        let token = ProcessInfo.processInfo.environment["HF_TOKEN"]
        if let token {
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

        // Build file list with known sizes
        let files: [(name: String, size: Int64)] = siblings.compactMap { entry -> (String, Int64)? in
            guard let name = entry["rfilename"] as? String else { return nil }
            let size = (entry["size"] as? Int64) ?? (entry["size"] as? Int).map(Int64.init) ?? 0
            return (name, size)
        }
        let totalBytes: Int64 = files.reduce(0) { $0 + $1.size }
        var downloadedBytes: Int64 = 0

        await progress(DownloadProgress(
            phase: .starting,
            currentFile: "",
            fileIndex: 0,
            fileCount: files.count,
            fileBytes: 0,
            fileTotalBytes: 0,
            overallBytes: 0,
            overallTotalBytes: totalBytes
        ))

        for (index, file) in files.enumerated() {
            let fileURL = URL(string: "https://huggingface.co/\(modelId)/resolve/main/\(file.name)")!
            var req = URLRequest(url: fileURL)
            if let token {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            let dest = dir.appendingPathComponent(file.name)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            // Download file — use streaming on macOS, bulk on Linux
            let fileReceived: Int64

            #if canImport(FoundationNetworking)
            // Linux: FoundationNetworking lacks .bytes(for:), use .data(for:)
            let (fileData, _) = try await URLSession.shared.data(for: req)
            try fileData.write(to: dest)
            fileReceived = Int64(fileData.count)

            await progress(DownloadProgress(
                phase: .downloading,
                currentFile: file.name,
                fileIndex: index,
                fileCount: files.count,
                fileBytes: fileReceived,
                fileTotalBytes: file.size,
                overallBytes: downloadedBytes + fileReceived,
                overallTotalBytes: totalBytes
            ))
            #else
            // macOS: stream download with per-chunk progress
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            let expectedLength = (response as? HTTPURLResponse)
                .flatMap { Int64($0.value(forHTTPHeaderField: "Content-Length") ?? "") }
                ?? file.size

            var fileData = Data()
            if expectedLength > 0 {
                fileData.reserveCapacity(Int(expectedLength))
            }
            var chunkReceived: Int64 = 0
            let reportInterval: Int64 = max(expectedLength / 200, 65536)

            for try await byte in bytes {
                fileData.append(byte)
                chunkReceived += 1

                if chunkReceived % reportInterval == 0 || chunkReceived == expectedLength {
                    await progress(DownloadProgress(
                        phase: .downloading,
                        currentFile: file.name,
                        fileIndex: index,
                        fileCount: files.count,
                        fileBytes: chunkReceived,
                        fileTotalBytes: expectedLength,
                        overallBytes: downloadedBytes + chunkReceived,
                        overallTotalBytes: totalBytes
                    ))
                }
            }

            try fileData.write(to: dest)
            fileReceived = chunkReceived
            #endif

            downloadedBytes += fileReceived

            await progress(DownloadProgress(
                phase: .fileComplete,
                currentFile: file.name,
                fileIndex: index,
                fileCount: files.count,
                fileBytes: fileReceived,
                fileTotalBytes: expectedLength,
                overallBytes: downloadedBytes,
                overallTotalBytes: totalBytes
            ))
        }

        await progress(DownloadProgress(
            phase: .complete,
            currentFile: "",
            fileIndex: files.count,
            fileCount: files.count,
            fileBytes: 0,
            fileTotalBytes: 0,
            overallBytes: downloadedBytes,
            overallTotalBytes: totalBytes
        ))
    }
}

/// Progress state reported during model download.
public struct DownloadProgress: Sendable {
    public enum Phase: Sendable {
        case starting
        case downloading
        case fileComplete
        case complete
    }
    public let phase: Phase
    public let currentFile: String
    public let fileIndex: Int
    public let fileCount: Int
    public let fileBytes: Int64
    public let fileTotalBytes: Int64
    public let overallBytes: Int64
    public let overallTotalBytes: Int64

    public var overallPercent: Int {
        guard overallTotalBytes > 0 else { return 0 }
        return Int(Double(overallBytes) / Double(overallTotalBytes) * 100)
    }

    public var overallGBDownloaded: Double {
        Double(overallBytes) / 1_000_000_000
    }

    public var overallGBTotal: Double {
        Double(overallTotalBytes) / 1_000_000_000
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
