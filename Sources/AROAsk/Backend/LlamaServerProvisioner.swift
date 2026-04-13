// ============================================================
// LlamaServerProvisioner.swift
// AROAsk - auto-downloads llama-server for Linux
// ============================================================
//
// On Linux, `aro ask` needs llama-server (llama.cpp) to run LLM inference.
// This provisioner automatically downloads the correct pre-built binary
// from the llama.cpp GitHub releases on first use.
//
// Cached at ~/.cache/aro/bin/llama-server — subsequent runs are instant.

import Foundation

/// Downloads and caches `llama-server` from llama.cpp GitHub releases.
public enum LlamaServerProvisioner {

    /// Directory where the binary is cached.
    static var cacheDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache")
            .appendingPathComponent("aro")
            .appendingPathComponent("bin")
    }

    /// Path to the cached llama-server binary.
    static var cachedBinary: URL {
        cacheDir.appendingPathComponent("llama-server")
    }

    /// Return the cached binary path if it exists and is executable.
    public static func cachedBinaryIfExists() -> String? {
        FileManager.default.isExecutableFile(atPath: cachedBinary.path)
            ? cachedBinary.path
            : nil
    }

    /// Offer to download llama-server if not available.
    /// Returns the path to the binary, or nil.
    public static func findOrProvision(
        confirm: @Sendable () async -> Bool
    ) async -> String? {
        // 1. Already on PATH
        if let path = ProcessRunner.which("llama-server") {
            return path
        }

        // 2. In our cache
        if FileManager.default.isExecutableFile(atPath: cachedBinary.path) {
            return cachedBinary.path
        }

        // 3. Offer to download
        FileHandle.standardError.write(Data(
            "\n  llama-server not found. It's required for `aro ask` on Linux.\n".utf8
        ))

        guard await confirm() else {
            return nil
        }

        do {
            try await download()
            return cachedBinary.path
        } catch {
            FileHandle.standardError.write(Data(
                "  Failed to download llama-server: \(error)\n".utf8
            ))
            return nil
        }
    }

    // MARK: - Download

    /// Detect the platform and download the matching llama-server binary.
    private static func download() async throws {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Determine which release asset to download
        let asset = try await resolveAsset()

        FileHandle.standardError.write(Data(
            "  Downloading \(asset.name) (\(formatSize(asset.size)))...\n".utf8
        ))

        // Download the archive
        let (data, response) = try await URLSession.shared.data(from: asset.url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LMBackendError.invalidResponse("Failed to download llama-server")
        }

        // The asset is a .zip or .tar.gz containing the binary
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-llama-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let archivePath = tempDir.appendingPathComponent(asset.name)
        try data.write(to: archivePath)

        // Extract
        let binary: URL
        if asset.name.hasSuffix(".zip") {
            binary = try extractZip(archivePath, to: tempDir)
        } else {
            binary = try extractTarGz(archivePath, to: tempDir)
        }

        // Move to cache
        if FileManager.default.fileExists(atPath: cachedBinary.path) {
            try FileManager.default.removeItem(at: cachedBinary)
        }
        try FileManager.default.copyItem(at: binary, to: cachedBinary)

        // Make executable
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: cachedBinary.path
        )

        // Verify it runs
        let result = try? ProcessRunner.runAndCapture(
            executable: cachedBinary.path,
            arguments: ["--version"],
            timeout: 5
        )
        let version = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        FileHandle.standardError.write(Data(
            "  Installed llama-server (\(version)) at \(cachedBinary.path)\n\n".utf8
        ))
    }

    // MARK: - Release resolution

    private struct ReleaseAsset {
        let name: String
        let url: URL
        let size: Int64
    }

    private static func resolveAsset() async throws -> ReleaseAsset {
        // Fetch latest release from GitHub API
        let apiURL = URL(string: "https://api.github.com/repos/ggerganov/llama.cpp/releases/latest")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else {
            throw LMBackendError.downloadFailed("Could not parse GitHub releases API")
        }

        // Find the right asset for this platform
        let pattern = assetPattern()
        guard let asset = assets.first(where: { ($0["name"] as? String ?? "").contains(pattern) }),
              let name = asset["name"] as? String,
              let urlStr = asset["browser_download_url"] as? String,
              let url = URL(string: urlStr) else {
            throw LMBackendError.downloadFailed(
                "No llama-server release found matching '\(pattern)'. "
                + "Install manually: https://github.com/ggerganov/llama.cpp/releases"
            )
        }

        let size = (asset["size"] as? Int64) ?? 0
        return ReleaseAsset(name: name, url: url, size: size)
    }

    /// Return the asset filename pattern for the current platform.
    private static func assetPattern() -> String {
        #if os(macOS)
        #if arch(arm64)
        return "macos-arm64"
        #else
        return "macos-x64"
        #endif
        #elseif os(Linux)
        #if arch(arm64)
        return "linux-arm64"
        #else
        // Prefer CUDA build if nvidia-smi is available
        if ProcessRunner.which("nvidia-smi") != nil {
            return "linux-x64-cuda"
        }
        return "linux-x64"
        #endif
        #else
        return "linux-x64"
        #endif
    }

    // MARK: - Archive extraction

    private static func extractZip(_ archive: URL, to dir: URL) throws -> URL {
        let result = try ProcessRunner.runAndCapture(
            executable: "/usr/bin/unzip",
            arguments: ["-o", archive.path, "-d", dir.path],
            timeout: 120
        )
        guard result.exitCode == 0 else {
            throw LMBackendError.downloadFailed("unzip failed: \(result.stderr)")
        }
        return try findBinary(in: dir)
    }

    private static func extractTarGz(_ archive: URL, to dir: URL) throws -> URL {
        let result = try ProcessRunner.runAndCapture(
            executable: "/usr/bin/tar",
            arguments: ["-xzf", archive.path, "-C", dir.path],
            timeout: 120
        )
        guard result.exitCode == 0 else {
            throw LMBackendError.downloadFailed("tar failed: \(result.stderr)")
        }
        return try findBinary(in: dir)
    }

    private static func findBinary(in dir: URL) throws -> URL {
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isExecutableKey]) {
            while let item = enumerator.nextObject() as? URL {
                if item.lastPathComponent == "llama-server" {
                    return item
                }
            }
        }
        throw LMBackendError.downloadFailed("llama-server binary not found in extracted archive")
    }

    // MARK: - Helpers

    private static func formatSize(_ bytes: Int64) -> String {
        if bytes > 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        }
        return String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
}

// Add downloadFailed case to ModelManagerError for reuse
extension LMBackendError {
    static func downloadFailed(_ msg: String) -> LMBackendError {
        .invalidResponse("Download failed: \(msg)")
    }
}
