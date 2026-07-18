// ============================================================
// FileOps.swift
// ARO CLI - Async wrappers around blocking FileManager calls
// ============================================================

import Foundation

/// Async wrappers that run blocking `FileManager` operations on a background
/// utility task.
///
/// CLI commands execute on the concurrency runtime's main thread. Directory
/// creation, enumeration, and removal performed inline can stall the terminal
/// on large plugin directories or slow disks (issue #365). These helpers hop
/// the blocking syscalls onto a detached utility-priority task so the calling
/// thread stays responsive, while preserving the exact `FileManager`
/// semantics: the same directories are created/removed and the same errors
/// are thrown.
enum FileOps {

    /// Run a blocking file-system operation on a background utility task and
    /// return its result. Use this for one-off compound operations (e.g. a
    /// scaffold that writes many files) that should not block the caller.
    static func background<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .utility) {
            try operation()
        }.value
    }

    /// `FileManager.createDirectory(at:withIntermediateDirectories: true)`
    /// off the calling thread.
    static func createDirectory(at url: URL) async throws {
        try await background {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Best-effort directory creation mirroring previous `try?` call sites.
    /// The fallback is acceptable because an already-existing directory is
    /// fine, and any real failure surfaces at the subsequent write into it.
    static func createDirectoryIfNeeded(at url: URL) async {
        try? await createDirectory(at: url)
    }

    /// `FileManager.removeItem(at:)` off the calling thread.
    static func removeItem(at url: URL) async throws {
        try await background {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Best-effort removal mirroring previous `try?` call sites. The fallback
    /// is acceptable because a missing item means there is nothing to clean up.
    static func removeItemIfPresent(at url: URL) async {
        try? await removeItem(at: url)
    }

    /// `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:)`
    /// off the calling thread.
    static func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]? = nil
    ) async throws -> [URL] {
        try await background {
            try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
        }
    }
}
