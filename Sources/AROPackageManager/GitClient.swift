// ============================================================
// GitClient.swift
// ARO Package Manager - Git Operations
// ============================================================

import Foundation

// MARK: - Git Client

/// Handles Git operations for the package manager
///
/// Provides a high-level interface for cloning, pulling, and checking out
/// Git repositories.
public final class GitClient: Sendable {
    /// Shared instance
    public static let shared = GitClient()

    private init() {}

    // MARK: - Clone

    /// Clone a Git repository
    /// - Parameters:
    ///   - url: Git repository URL (SSH or HTTPS)
    ///   - destination: Local destination path
    ///   - ref: Optional reference (branch, tag, or commit) to checkout
    /// - Returns: Information about the cloned repository
    public func clone(url: String, to destination: URL, ref: String? = nil) throws -> CloneResult {
        // Create parent directory if needed
        let parentDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Clone the repository
        var args = ["clone"]

        // If we have a specific ref, do a shallow clone for efficiency
        if let ref = ref {
            // For tags and branches, we can do shallow clone
            args.append(contentsOf: ["--depth", "1", "--branch", ref])
        }

        args.append(url)
        args.append(destination.path)

        do {
            try runGit(args)
        } catch let error as GitError {
            // If shallow clone with ref failed, try full clone
            if ref != nil && error.description.contains("Could not find remote branch") {
                // Full clone and checkout specific commit
                try runGit(["clone", url, destination.path])
                try checkout(ref: ref!, in: destination)
            } else {
                throw error
            }
        }

        // Get commit hash
        let commit = try getHeadCommit(in: destination)

        // Get current branch/ref
        let currentRef = ref ?? (try? getCurrentBranch(in: destination)) ?? "HEAD"

        return CloneResult(
            path: destination,
            ref: currentRef,
            commit: commit
        )
    }

    // MARK: - Checkout

    /// Checkout a specific reference
    /// - Parameters:
    ///   - ref: Branch, tag, or commit to checkout
    ///   - repository: Path to the repository
    public func checkout(ref: String, in repository: URL) throws {
        try runGit(["checkout", ref], in: repository)
    }

    // MARK: - Pull

    /// Pull latest changes
    /// - Parameter repository: Path to the repository
    public func pull(in repository: URL) throws {
        try runGit(["pull"], in: repository)
    }

    /// Fetch and reset to a specific ref
    /// - Parameters:
    ///   - ref: Reference to reset to
    ///   - repository: Path to the repository
    public func fetchAndReset(to ref: String, in repository: URL) throws {
        try runGit(["fetch", "origin"], in: repository)
        try runGit(["reset", "--hard", "origin/\(ref)"], in: repository)
    }

    // MARK: - Status

    /// Get the current HEAD commit hash
    /// - Parameter repository: Path to the repository
    /// - Returns: Full commit hash
    public func getHeadCommit(in repository: URL) throws -> String {
        let output = try runGitWithOutput(["rev-parse", "HEAD"], in: repository)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Get the current branch name
    /// - Parameter repository: Path to the repository
    /// - Returns: Branch name or nil if detached HEAD
    public func getCurrentBranch(in repository: URL) throws -> String? {
        let output = try runGitWithOutput(["rev-parse", "--abbrev-ref", "HEAD"], in: repository)
        let branch = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch == "HEAD" ? nil : branch
    }

    /// Check if a repository has uncommitted changes
    /// - Parameter repository: Path to the repository
    /// - Returns: True if there are uncommitted changes
    public func hasUncommittedChanges(in repository: URL) throws -> Bool {
        let output = try runGitWithOutput(["status", "--porcelain"], in: repository)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Get the remote URL for origin
    /// - Parameter repository: Path to the repository
    /// - Returns: Remote URL
    public func getRemoteURL(in repository: URL) throws -> String {
        let output = try runGitWithOutput(["remote", "get-url", "origin"], in: repository)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - URL Parsing

    /// Extract the repository name from a Git URL
    /// - Parameter url: Git URL (SSH or HTTPS)
    /// - Returns: Repository name without .git extension
    public func extractRepoName(from url: String) -> String {
        // Handle SSH URLs: git@github.com:user/repo.git
        // Handle HTTPS URLs: https://github.com/user/repo.git
        var name = url

        // Remove .git suffix
        if name.hasSuffix(".git") {
            name = String(name.dropLast(4))
        }

        // Extract last component
        if let lastSlash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: lastSlash)...])
        } else if let lastColon = name.lastIndex(of: ":") {
            // SSH format: git@host:user/repo
            let afterColon = name[name.index(after: lastColon)...]
            if let lastSlash = afterColon.lastIndex(of: "/") {
                name = String(afterColon[afterColon.index(after: lastSlash)...])
            } else {
                name = String(afterColon)
            }
        }

        return name
    }

    /// Parse a Git URL into components
    /// - Parameter url: Git URL
    /// - Returns: Parsed URL info
    public func parseURL(_ url: String) -> GitURLInfo {
        var host = ""
        var path = ""
        var isSSH = false

        if url.hasPrefix("git@") {
            // SSH format: git@github.com:user/repo.git
            isSSH = true
            let withoutPrefix = String(url.dropFirst(4))
            if let colonIndex = withoutPrefix.firstIndex(of: ":") {
                host = String(withoutPrefix[..<colonIndex])
                path = String(withoutPrefix[withoutPrefix.index(after: colonIndex)...])
            }
        } else if url.hasPrefix("https://") || url.hasPrefix("http://") {
            // HTTPS format: https://github.com/user/repo.git
            if let urlObj = URL(string: url) {
                host = urlObj.host ?? ""
                path = urlObj.path
                if path.hasPrefix("/") {
                    path = String(path.dropFirst())
                }
            }
        }

        // Remove .git suffix from path
        if path.hasSuffix(".git") {
            path = String(path.dropLast(4))
        }

        return GitURLInfo(
            originalURL: url,
            host: host,
            path: path,
            isSSH: isSSH,
            repoName: extractRepoName(from: url)
        )
    }

    // MARK: - Private

    /// Run a git command
    private func runGit(_ arguments: [String], in directory: URL? = nil) throws {
        _ = try runGitWithOutput(arguments, in: directory)
    }

    /// Run a git command and return output
    private func runGitWithOutput(_ arguments: [String], in directory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments

        if let directory = directory {
            process.currentDirectoryURL = directory
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw GitError.commandFailed(
                command: "git \(arguments.joined(separator: " "))",
                exitCode: Int(process.terminationStatus),
                stderr: errorOutput
            )
        }

        return output
    }
}

// MARK: - Clone Result

/// Result of a clone operation
public struct CloneResult: Sendable {
    /// Path to the cloned repository
    public let path: URL

    /// Reference that was checked out
    public let ref: String

    /// Full commit hash
    public let commit: String
}

// MARK: - Git URL Info

/// Parsed Git URL information
public struct GitURLInfo: Sendable {
    /// Original URL string
    public let originalURL: String

    /// Host (e.g., github.com)
    public let host: String

    /// Path (e.g., user/repo)
    public let path: String

    /// Whether this is an SSH URL
    public let isSSH: Bool

    /// Repository name
    public let repoName: String
}

// MARK: - Git Errors

/// Errors that can occur during Git operations
public enum GitError: Error, CustomStringConvertible {
    case commandFailed(command: String, exitCode: Int, stderr: String)
    case notARepository(String)
    case invalidURL(String)

    public var description: String {
        switch self {
        case .commandFailed(let command, let exitCode, let stderr):
            return "Git command failed: \(command) (exit \(exitCode))\n\(stderr)"
        case .notARepository(let path):
            return "Not a Git repository: \(path)"
        case .invalidURL(let url):
            return "Invalid Git URL: \(url)"
        }
    }
}
