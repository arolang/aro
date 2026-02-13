// ============================================================
// GitClient.swift
// ARO Package Manager - Git Operations via libgit2
// ============================================================

import Foundation
import Clibgit2

// MARK: - Git Client

/// Handles Git operations for the package manager using libgit2
///
/// Provides a high-level interface for cloning, pulling, and checking out
/// Git repositories without spawning external processes.
public final class GitClient: @unchecked Sendable {
    /// Shared instance
    public static let shared = GitClient()

    /// Lock for thread safety during libgit2 operations (recursive to allow nested calls)
    private let lock = NSRecursiveLock()

    /// Lock for initialization
    private static let initLock = NSLock()

    /// Whether libgit2 has been initialized
    nonisolated(unsafe) private static var initialized = false

    private init() {
        GitClient.initializeLibgit2()
    }

    deinit {
        // Note: We don't call git_libgit2_shutdown() here because
        // the shared instance lives for the lifetime of the process
    }

    /// Initialize libgit2 (thread-safe, called once)
    private static func initializeLibgit2() {
        initLock.lock()
        defer { initLock.unlock() }
        guard !initialized else { return }
        git_libgit2_init()
        initialized = true
    }

    // MARK: - Clone

    /// Clone a Git repository
    /// - Parameters:
    ///   - url: Git repository URL (SSH or HTTPS)
    ///   - destination: Local destination path
    ///   - ref: Optional reference (branch, tag, or commit) to checkout
    /// - Returns: Information about the cloned repository
    public func clone(url: String, to destination: URL, ref: String? = nil) throws -> CloneResult {
        lock.lock()
        defer { lock.unlock() }

        // Create parent directory if needed
        let parentDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        var repo: OpaquePointer?
        var options = git_clone_options()
        git_clone_options_init(&options, UInt32(GIT_CLONE_OPTIONS_VERSION))

        // Set up fetch options for progress and credentials
        setupFetchOptions(&options.fetch_opts)

        // If we have a specific branch ref, set it
        var branchCStr: UnsafeMutablePointer<CChar>? = nil
        if let ref = ref, !isCommitHash(ref) {
            branchCStr = strdup(ref)
            options.checkout_branch = UnsafePointer(branchCStr)
        }

        // Clone the repository
        let result = url.withCString { urlCStr in
            destination.path.withCString { pathCStr in
                git_clone(&repo, urlCStr, pathCStr, &options)
            }
        }

        // Free the checkout branch string if we allocated it
        if let branchPtr = branchCStr {
            free(branchPtr)
        }

        if result != 0 {
            throw gitError("Clone failed")
        }

        defer { git_repository_free(repo) }

        // If ref is a commit hash, checkout that specific commit
        if let ref = ref, isCommitHash(ref) {
            try checkout(ref: ref, in: destination)
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
        lock.lock()
        defer { lock.unlock() }

        var repo: OpaquePointer?
        let openResult = repository.path.withCString { pathCStr in
            git_repository_open(&repo, pathCStr)
        }

        if openResult != 0 {
            throw GitError.notARepository(repository.path)
        }

        defer { git_repository_free(repo) }

        // Try to resolve the reference
        var obj: OpaquePointer?
        let resolveResult = ref.withCString { refCStr in
            git_revparse_single(&obj, repo, refCStr)
        }

        if resolveResult != 0 {
            throw gitError("Cannot resolve reference: \(ref)")
        }

        defer { git_object_free(obj) }

        // Checkout the object
        var checkoutOpts = git_checkout_options()
        git_checkout_options_init(&checkoutOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOpts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue

        let checkoutResult = git_checkout_tree(repo, obj, &checkoutOpts)
        if checkoutResult != 0 {
            throw gitError("Checkout failed")
        }

        // Update HEAD
        let objectType = git_object_type(obj)
        if objectType == GIT_OBJECT_COMMIT {
            // Detach HEAD to the commit
            let oid = git_object_id(obj)
            let headResult = git_repository_set_head_detached(repo, oid)
            if headResult != 0 {
                throw gitError("Failed to update HEAD")
            }
        }
    }

    // MARK: - Pull

    /// Pull latest changes (fetch + merge)
    /// - Parameter repository: Path to the repository
    public func pull(in repository: URL) throws {
        lock.lock()
        defer { lock.unlock() }

        var repo: OpaquePointer?
        let openResult = repository.path.withCString { pathCStr in
            git_repository_open(&repo, pathCStr)
        }

        if openResult != 0 {
            throw GitError.notARepository(repository.path)
        }

        defer { git_repository_free(repo) }

        // Get the remote
        var remote: OpaquePointer?
        let remoteResult = "origin".withCString { nameCStr in
            git_remote_lookup(&remote, repo, nameCStr)
        }

        if remoteResult != 0 {
            throw gitError("Cannot find remote 'origin'")
        }

        defer { git_remote_free(remote) }

        // Fetch
        var fetchOpts = git_fetch_options()
        git_fetch_options_init(&fetchOpts, UInt32(GIT_FETCH_OPTIONS_VERSION))
        setupFetchOptions(&fetchOpts)

        let fetchResult = git_remote_fetch(remote, nil, &fetchOpts, nil)
        if fetchResult != 0 {
            throw gitError("Fetch failed")
        }

        // Fast-forward merge (simplified - assumes tracking branch)
        try fastForwardMerge(repo: repo)
    }

    /// Fetch and reset to a specific ref
    /// - Parameters:
    ///   - ref: Reference to reset to
    ///   - repository: Path to the repository
    public func fetchAndReset(to ref: String, in repository: URL) throws {
        lock.lock()
        defer { lock.unlock() }

        var repo: OpaquePointer?
        let openResult = repository.path.withCString { pathCStr in
            git_repository_open(&repo, pathCStr)
        }

        if openResult != 0 {
            throw GitError.notARepository(repository.path)
        }

        defer { git_repository_free(repo) }

        // Get the remote
        var remote: OpaquePointer?
        let remoteResult = "origin".withCString { nameCStr in
            git_remote_lookup(&remote, repo, nameCStr)
        }

        if remoteResult != 0 {
            throw gitError("Cannot find remote 'origin'")
        }

        defer { git_remote_free(remote) }

        // Fetch
        var fetchOpts = git_fetch_options()
        git_fetch_options_init(&fetchOpts, UInt32(GIT_FETCH_OPTIONS_VERSION))
        setupFetchOptions(&fetchOpts)

        let fetchResult = git_remote_fetch(remote, nil, &fetchOpts, nil)
        if fetchResult != 0 {
            throw gitError("Fetch failed")
        }

        // Resolve origin/ref
        let remoteRef = "origin/\(ref)"
        var obj: OpaquePointer?
        let resolveResult = remoteRef.withCString { refCStr in
            git_revparse_single(&obj, repo, refCStr)
        }

        if resolveResult != 0 {
            throw gitError("Cannot resolve reference: \(remoteRef)")
        }

        defer { git_object_free(obj) }

        // Hard reset
        let resetResult = git_reset(repo, obj, GIT_RESET_HARD, nil)
        if resetResult != 0 {
            throw gitError("Reset failed")
        }
    }

    // MARK: - Status

    /// Get the current HEAD commit hash
    /// - Parameter repository: Path to the repository
    /// - Returns: Full commit hash
    public func getHeadCommit(in repository: URL) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        var repo: OpaquePointer?
        let openResult = repository.path.withCString { pathCStr in
            git_repository_open(&repo, pathCStr)
        }

        if openResult != 0 {
            throw GitError.notARepository(repository.path)
        }

        defer { git_repository_free(repo) }

        var head: OpaquePointer?
        let headResult = git_repository_head(&head, repo)
        if headResult != 0 {
            throw gitError("Cannot get HEAD")
        }

        defer { git_reference_free(head) }

        let oid = git_reference_target(head)
        guard let oid = oid else {
            throw gitError("Cannot get HEAD target")
        }

        return oidToString(oid)
    }

    /// Get the current branch name
    /// - Parameter repository: Path to the repository
    /// - Returns: Branch name or nil if detached HEAD
    public func getCurrentBranch(in repository: URL) throws -> String? {
        lock.lock()
        defer { lock.unlock() }

        var repo: OpaquePointer?
        let openResult = repository.path.withCString { pathCStr in
            git_repository_open(&repo, pathCStr)
        }

        if openResult != 0 {
            throw GitError.notARepository(repository.path)
        }

        defer { git_repository_free(repo) }

        var head: OpaquePointer?
        let headResult = git_repository_head(&head, repo)
        if headResult != 0 {
            return nil
        }

        defer { git_reference_free(head) }

        if git_reference_is_branch(head) == 1 {
            let name = git_reference_shorthand(head)
            if let name = name {
                return String(cString: name)
            }
        }

        return nil
    }

    /// Check if a repository has uncommitted changes
    /// - Parameter repository: Path to the repository
    /// - Returns: True if there are uncommitted changes
    public func hasUncommittedChanges(in repository: URL) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        var repo: OpaquePointer?
        let openResult = repository.path.withCString { pathCStr in
            git_repository_open(&repo, pathCStr)
        }

        if openResult != 0 {
            throw GitError.notARepository(repository.path)
        }

        defer { git_repository_free(repo) }

        var statusOpts = git_status_options()
        git_status_options_init(&statusOpts, UInt32(GIT_STATUS_OPTIONS_VERSION))
        statusOpts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        statusOpts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue

        var statusList: OpaquePointer?
        let statusResult = git_status_list_new(&statusList, repo, &statusOpts)
        if statusResult != 0 {
            throw gitError("Cannot get status")
        }

        defer { git_status_list_free(statusList) }

        let count = git_status_list_entrycount(statusList)
        return count > 0
    }

    /// Get the remote URL for origin
    /// - Parameter repository: Path to the repository
    /// - Returns: Remote URL
    public func getRemoteURL(in repository: URL) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        var repo: OpaquePointer?
        let openResult = repository.path.withCString { pathCStr in
            git_repository_open(&repo, pathCStr)
        }

        if openResult != 0 {
            throw GitError.notARepository(repository.path)
        }

        defer { git_repository_free(repo) }

        var remote: OpaquePointer?
        let remoteResult = "origin".withCString { nameCStr in
            git_remote_lookup(&remote, repo, nameCStr)
        }

        if remoteResult != 0 {
            throw gitError("Cannot find remote 'origin'")
        }

        defer { git_remote_free(remote) }

        let url = git_remote_url(remote)
        if let url = url {
            return String(cString: url)
        }

        throw gitError("Cannot get remote URL")
    }

    // MARK: - URL Parsing

    /// Extract the repository name from a Git URL
    /// - Parameter url: Git URL (SSH or HTTPS)
    /// - Returns: Repository name without .git extension
    public func extractRepoName(from url: String) -> String {
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

    // MARK: - Private Helpers

    /// Set up fetch options with credential callbacks
    private func setupFetchOptions(_ opts: inout git_fetch_options) {
        // Certificate check callback - accept all certificates
        // This is needed because libgit2's certificate verification can have issues on macOS
        opts.callbacks.certificate_check = { (cert, valid, host, payload) -> Int32 in
            return 0  // Accept certificate
        }

        // Set up callbacks for SSH authentication
        opts.callbacks.credentials = { (cred, url, username_from_url, allowed_types, payload) -> Int32 in
            // For HTTPS URLs that don't require authentication, return GIT_PASSTHROUGH
            // to let libgit2 continue without credentials
            if allowed_types == 0 {
                return Int32(GIT_PASSTHROUGH.rawValue)
            }

            // Try SSH key authentication
            if (allowed_types & GIT_CREDENTIAL_SSH_KEY.rawValue) != 0 {
                let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

                // Check for ed25519 keys first, then RSA
                let privateKeyEd = "\(homeDir)/.ssh/id_ed25519"
                let publicKeyEd = "\(homeDir)/.ssh/id_ed25519.pub"
                let privateKey = "\(homeDir)/.ssh/id_rsa"
                let publicKey = "\(homeDir)/.ssh/id_rsa.pub"

                let (privKey, pubKey): (String, String)
                if FileManager.default.fileExists(atPath: privateKeyEd) {
                    (privKey, pubKey) = (privateKeyEd, publicKeyEd)
                } else if FileManager.default.fileExists(atPath: privateKey) {
                    (privKey, pubKey) = (privateKey, publicKey)
                } else {
                    // Try SSH agent if no key files found
                    let username = username_from_url != nil ? String(cString: username_from_url!) : "git"
                    return username.withCString { userCStr in
                        git_credential_ssh_key_from_agent(cred, userCStr)
                    }
                }

                let username = username_from_url != nil ? String(cString: username_from_url!) : "git"

                return username.withCString { userCStr in
                    pubKey.withCString { pubCStr in
                        privKey.withCString { privCStr in
                            git_credential_ssh_key_new(cred, userCStr, pubCStr, privCStr, nil)
                        }
                    }
                }
            }

            // For userpass (HTTPS with auth), return passthrough to skip
            if (allowed_types & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue) != 0 {
                return Int32(GIT_PASSTHROUGH.rawValue)
            }

            return Int32(GIT_PASSTHROUGH.rawValue)
        }
    }

    /// Perform a fast-forward merge
    private func fastForwardMerge(repo: OpaquePointer?) throws {
        guard let repo = repo else { return }

        // Get the current branch's upstream
        var head: OpaquePointer?
        let headResult = git_repository_head(&head, repo)
        if headResult != 0 {
            throw gitError("Cannot get HEAD")
        }
        defer { git_reference_free(head) }

        // Get upstream reference name
        var upstream: OpaquePointer?
        let upstreamResult = git_branch_upstream(&upstream, head)
        if upstreamResult != 0 {
            // No upstream, nothing to merge
            return
        }
        defer { git_reference_free(upstream) }

        // Get the upstream commit
        let upstreamOid = git_reference_target(upstream)
        guard let upstreamOid = upstreamOid else {
            throw gitError("Cannot get upstream target")
        }

        var upstreamCommit: OpaquePointer?
        let commitResult = git_commit_lookup(&upstreamCommit, repo, upstreamOid)
        if commitResult != 0 {
            throw gitError("Cannot lookup upstream commit")
        }
        defer { git_commit_free(upstreamCommit) }

        // Check if we can fast-forward
        var analysis: git_merge_analysis_t = GIT_MERGE_ANALYSIS_NONE
        var preference: git_merge_preference_t = GIT_MERGE_PREFERENCE_NONE

        var annotated: OpaquePointer?
        let annotateResult = git_annotated_commit_from_ref(&annotated, repo, upstream)
        if annotateResult != 0 {
            throw gitError("Cannot create annotated commit")
        }
        defer { git_annotated_commit_free(annotated) }

        var heads: [OpaquePointer?] = [annotated]
        let analysisResult = withUnsafeMutablePointer(to: &heads[0]) { headsPtr in
            git_merge_analysis(&analysis, &preference, repo, headsPtr, 1)
        }
        if analysisResult != 0 {
            throw gitError("Merge analysis failed")
        }

        if analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0 {
            // Fast-forward is possible
            let targetOid = git_annotated_commit_id(annotated)
            var newHead: OpaquePointer?

            let ffResult = git_reference_set_target(&newHead, head, targetOid, "fast-forward")
            if ffResult != 0 {
                throw gitError("Fast-forward failed")
            }
            git_reference_free(newHead)

            // Checkout the new HEAD
            var checkoutOpts = git_checkout_options()
            git_checkout_options_init(&checkoutOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
            checkoutOpts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue

            let checkoutResult = git_checkout_head(repo, &checkoutOpts)
            if checkoutResult != 0 {
                throw gitError("Checkout after fast-forward failed")
            }
        } else if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
            // Already up to date
            return
        } else {
            throw gitError("Cannot fast-forward, manual merge required")
        }
    }

    /// Convert git_oid to hex string
    private func oidToString(_ oid: UnsafePointer<git_oid>) -> String {
        var buffer = [CChar](repeating: 0, count: 41)
        git_oid_tostr(&buffer, 41, oid)
        // Convert CChar array to String, truncating at null terminator
        let data = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Check if a string looks like a commit hash
    private func isCommitHash(_ ref: String) -> Bool {
        guard ref.count >= 7 && ref.count <= 40 else { return false }
        return ref.allSatisfy { $0.isHexDigit }
    }

    /// Create a GitError from the last libgit2 error
    private func gitError(_ context: String) -> GitError {
        let error = git_error_last()
        if let error = error, let message = error.pointee.message {
            return .commandFailed(
                command: context,
                exitCode: Int(error.pointee.klass),
                stderr: String(cString: message)
            )
        }
        return .commandFailed(command: context, exitCode: -1, stderr: "Unknown error")
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
            return "Git operation failed: \(command) (code \(exitCode))\n\(stderr)"
        case .notARepository(let path):
            return "Not a Git repository: \(path)"
        case .invalidURL(let url):
            return "Invalid Git URL: \(url)"
        }
    }
}
