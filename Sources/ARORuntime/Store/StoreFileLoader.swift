// ============================================================
// StoreFileLoader.swift
// ARO Runtime - Store File Discovery and Parsing
// ============================================================
//
// Discovers .store files in an ARO application directory and
// parses them into repository seed data. File permissions
// determine writability: if the POSIX "other write" bit (o+w)
// is set, the store is writable and changes persist to disk.

import Foundation

/// Describes a discovered .store file and its parsed content
public struct StoreFileDescriptor: Sendable {
    /// Absolute path to the .store file
    public let filePath: URL

    /// Repository name derived from filename (e.g., "users-repository" from "users.store")
    public let repositoryName: String

    /// Whether the store is writable (POSIX other-write bit set)
    public let isWritable: Bool

    /// Parsed entries from the YAML content
    public let entries: [[String: any Sendable]]
}

/// Discovers and parses .store files in an ARO application directory
public struct StoreFileLoader: Sendable {

    public init() {}

    /// Discover all .store files in the given application directory
    /// - Parameter rootPath: The application root directory
    /// - Returns: Array of store file descriptors
    public func discover(in rootPath: URL) throws -> [StoreFileDescriptor] {
        let fm = FileManager.default
        var descriptors: [StoreFileDescriptor] = []

        // Enumerate files in the root directory (non-recursive — .store files
        // live alongside main.aro and openapi.yaml)
        guard let enumerator = fm.enumerator(
            at: rootPath,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "store" else { continue }

            let descriptor = try parseStoreFile(at: fileURL)
            descriptors.append(descriptor)
        }

        return descriptors.sorted { $0.repositoryName < $1.repositoryName }
    }

    /// Parse a single .store file
    /// - Parameter fileURL: Path to the .store file
    /// - Returns: A store file descriptor with parsed entries and permission info
    func parseStoreFile(at fileURL: URL) throws -> StoreFileDescriptor {
        let fm = FileManager.default

        // Derive repository name: filename without extension + "-repository"
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let repositoryName = "\(stem)-repository"

        // Read and parse YAML content
        let content = try String(contentsOf: fileURL, encoding: .utf8)

        let isWritable: Bool
        #if os(Windows)
        // ARO-0073 §3 makes persistence opt-in through the POSIX other-write
        // bit. Windows has no such bit, and the fallback here asked
        // `isWritableFile`, which is true for any file the current user owns —
        // so every `.store` was writable and a seed file the author meant to
        // be read-only was silently rewritten at shutdown. The contract was
        // inverted, not merely approximated (GitLab #684).
        //
        // The opt-in Windows gets instead is an explicit marker in the file.
        // ARO-0073 rejected a YAML header for POSIX because permissions were
        // already there; on Windows there is nothing to prefer it to, and the
        // alternative is no opt-in at all. The marker is a comment, so the
        // file stays valid YAML and stays portable: carried to a POSIX host it
        // is simply not consulted, and the store is read-only until someone
        // runs `chmod o+w`. That is the safe direction for a file to drift in.
        isWritable = Self.declaresWindowsWritability(content)
        #else
        let attributes = try fm.attributesOfItem(atPath: fileURL.path)
        if let permissions = attributes[.posixPermissions] as? Int {
            // Check other-write bit (0o002)
            isWritable = (permissions & 0o002) != 0
        } else {
            isWritable = false
        }
        #endif
        let entries = parseYAMLEntries(content, filePath: fileURL)

        // Clean up stale .tmp file from previous crash if present
        let tmpURL = fileURL.appendingPathExtension("tmp")
        if fm.fileExists(atPath: tmpURL.path) {
            try? fm.removeItem(at: tmpURL)
        }

        return StoreFileDescriptor(
            filePath: fileURL,
            repositoryName: repositoryName,
            isWritable: isWritable,
            entries: entries
        )
    }

    /// Whether a `.store` file opts in to write-back on Windows.
    ///
    /// The marker is `# aro-store: writable`, and it must appear in the
    /// leading comment block — before the first entry — so that it cannot be
    /// smuggled in as part of the data. Matching is case-insensitive and
    /// tolerant of spacing, because the only thing worse than a marker is a
    /// marker that looks right and does nothing.
    ///
    /// Read-only is the default, including for a file with no marker, an
    /// unreadable one, or one whose marker appears after data has started.
    /// Internal rather than private so the rule is testable on every platform
    /// — the branch that uses it only compiles on Windows (GitLab #684).
    static func declaresWindowsWritability(_ content: String) -> Bool {
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard line.hasPrefix("#") else {
                // Data has started; a marker below it is not a header.
                return false
            }
            let directive = line.dropFirst()
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard directive.hasPrefix("aro-store:") else { continue }
            let value = directive.dropFirst("aro-store:".count).trimmingCharacters(in: .whitespaces)
            if value == "writable" { return true }
        }
        return false
    }

    /// Parse YAML content into an array of dictionary entries
    private func parseYAMLEntries(_ content: String, filePath: URL) -> [[String: any Sendable]] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let deserialized = FormatDeserializer.deserialize(trimmed, format: .yaml)

        // If the result is an array, extract dictionary entries
        if let array = deserialized as? [Any] {
            return array.compactMap { item -> [String: any Sendable]? in
                if let dict = item as? [String: Any] {
                    var sendableDict: [String: any Sendable] = [:]
                    for (key, value) in dict {
                        sendableDict[key] = convertToSendable(value)
                    }
                    return sendableDict
                }
                return nil
            }
        }

        // If a single dictionary, wrap in array
        if let dict = deserialized as? [String: Any] {
            var sendableDict: [String: any Sendable] = [:]
            for (key, value) in dict {
                sendableDict[key] = convertToSendable(value)
            }
            return [sendableDict]
        }

        return []
    }

    /// Convert Any to Sendable recursively
    private func convertToSendable(_ value: Any) -> any Sendable {
        SendableConverter.fromJSON(value)
    }
}
