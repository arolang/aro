// ============================================================
// GitService.swift
// ARO Runtime - Git Operations via libgit2 (ARO-0080)
// ============================================================

#if !os(Windows)

import Foundation
import Clibgit2

// MARK: - Git Service

/// Provides Git operations for ARO Git Actions using libgit2 directly.
///
/// When `git-repository` is used without a qualifier, the current working
/// directory is assumed. An explicit path qualifier overrides this.
public final class GitService: @unchecked Sendable {

    public static let shared = GitService()

    private let lock = NSRecursiveLock()
    private static let initLock = NSLock()
    nonisolated(unsafe) private static var initialized = false

    private init() {
        Self.initializeLibgit2()
    }

    private static func initializeLibgit2() {
        initLock.lock()
        defer { initLock.unlock() }
        guard !initialized else { return }
        git_libgit2_init()
        initialized = true
    }

    // MARK: - Repository helpers

    /// Open a repository, run `body`, then free it.
    private func withRepo<T>(at path: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var repo: OpaquePointer?
        let rc = path.path.withCString { git_repository_open(&repo, $0) }
        guard rc == 0, let repo else { throw GitServiceError.notARepository(path.path) }
        defer { git_repository_free(repo) }
        return try body(repo)
    }

    /// Resolve a repository path from an ARO object qualifier.
    /// `nil` or `"."` means the current working directory.
    public func resolveRepoPath(_ qualifier: String?) -> URL {
        if let q = qualifier, !q.isEmpty, q != "." {
            if q.hasPrefix("/") {
                return URL(fileURLWithPath: q)
            }
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(q)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    // MARK: - Status

    /// Detailed repository status.
    public func status(in repoURL: URL) throws -> GitStatus {
        try withRepo(at: repoURL) { repo in
            let branch = currentBranchName(repo)
            let commit = headCommitHash(repo)

            var opts = git_status_options()
            git_status_options_init(&opts, UInt32(GIT_STATUS_OPTIONS_VERSION))
            opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
            opts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue |
                         GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue

            var list: OpaquePointer?
            guard git_status_list_new(&list, repo, &opts) == 0 else {
                throw gitError("Cannot get status")
            }
            defer { git_status_list_free(list) }

            var files: [[String: String]] = []
            let count = git_status_list_entrycount(list)
            for i in 0..<count {
                guard let entry = git_status_byindex(list, i) else { continue }
                let s = entry.pointee.status
                let statusLabel: String
                if s.rawValue & GIT_STATUS_WT_NEW.rawValue != 0          { statusLabel = "untracked" }
                else if s.rawValue & GIT_STATUS_INDEX_NEW.rawValue != 0  { statusLabel = "added" }
                else if s.rawValue & GIT_STATUS_WT_MODIFIED.rawValue != 0 ||
                        s.rawValue & GIT_STATUS_INDEX_MODIFIED.rawValue != 0 { statusLabel = "modified" }
                else if s.rawValue & GIT_STATUS_WT_DELETED.rawValue != 0 ||
                        s.rawValue & GIT_STATUS_INDEX_DELETED.rawValue != 0 { statusLabel = "deleted" }
                else if s.rawValue & GIT_STATUS_INDEX_RENAMED.rawValue != 0 { statusLabel = "renamed" }
                else { statusLabel = "changed" }

                let path: String
                if let diff = entry.pointee.head_to_index, let old = diff.pointee.old_file.path {
                    path = String(cString: old)
                } else if let diff = entry.pointee.index_to_workdir, let old = diff.pointee.old_file.path {
                    path = String(cString: old)
                } else {
                    path = "unknown"
                }
                files.append(["path": path, "status": statusLabel])
            }

            return GitStatus(
                branch: branch,
                commit: commit,
                clean: files.isEmpty,
                files: files
            )
        }
    }

    // MARK: - Stage

    /// Stage files for commit. Pass `["."]` to stage all.
    public func stage(files: [String], in repoURL: URL) throws {
        try withRepo(at: repoURL) { repo in
            var index: OpaquePointer?
            guard git_repository_index(&index, repo) == 0, let index else {
                throw gitError("Cannot open index")
            }
            defer { git_index_free(index) }

            for file in files {
                if file == "." {
                    var pattern = strdup("*")
                    defer { free(pattern) }
                    var arr = git_strarray(strings: &pattern, count: 1)
                    git_index_add_all(index, &arr, GIT_INDEX_ADD_DEFAULT.rawValue, nil, nil)
                } else {
                    file.withCString { pathCStr in
                        git_index_add_bypath(index, pathCStr)
                    }
                }
            }
            git_index_write(index)
        }
    }

    // MARK: - Commit

    /// Create a commit with the currently staged changes.
    public func commit(message: String, author: String? = nil, in repoURL: URL) throws -> GitCommitResult {
        try withRepo(at: repoURL) { repo in
            // Get index and write tree
            var index: OpaquePointer?
            guard git_repository_index(&index, repo) == 0, let index else {
                throw gitError("Cannot open index")
            }
            defer { git_index_free(index) }

            var treeOid = git_oid()
            guard git_index_write_tree(&treeOid, index) == 0 else {
                throw gitError("Cannot write tree")
            }

            var tree: OpaquePointer?
            guard git_tree_lookup(&tree, repo, &treeOid) == 0, let tree else {
                throw gitError("Cannot lookup tree")
            }
            defer { git_tree_free(tree) }

            // Resolve signature
            var sig: UnsafeMutablePointer<git_signature>?
            if let author, author.contains("<") {
                let parts = author.components(separatedBy: "<")
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                let email = parts.count > 1 ? parts[1].replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces) : ""
                git_signature_now(&sig, name, email)
            } else {
                git_signature_default(&sig, repo)
                if sig == nil { git_signature_now(&sig, "ARO", "aro@localhost") }
            }
            defer { if let sig { git_signature_free(sig) } }
            guard let sig else { throw gitError("Cannot create signature") }

            // Get parent commit (HEAD) if it exists
            var parentCommit: OpaquePointer?
            var headRef: OpaquePointer?
            let hasHead = git_repository_head(&headRef, repo) == 0
            if hasHead, let headRef {
                let oid = git_reference_target(headRef)
                git_commit_lookup(&parentCommit, repo, oid)
                git_reference_free(headRef)
            }
            defer { if let parentCommit { git_commit_free(parentCommit) } }

            // Create commit
            var commitOid = git_oid()
            let parentCount = parentCommit != nil ? 1 : 0
            var parentPtr = parentCommit
            let rc = message.withCString { msgCStr in
                "HEAD".withCString { refCStr in
                    git_commit_create(&commitOid, repo, refCStr, sig, sig, nil, msgCStr,
                                      tree, parentCount, &parentPtr)
                }
            }
            guard rc == 0 else { throw gitError("Cannot create commit") }

            var hashBuf = [CChar](repeating: 0, count: 41)
            git_oid_tostr(&hashBuf, 41, &commitOid)
            let hash = String(cString: hashBuf)

            let authorName: String
            if let namePtr = sig.pointee.name {
                authorName = String(cString: namePtr)
            } else {
                authorName = "unknown"
            }

            return GitCommitResult(
                hash: hash,
                short: String(hash.prefix(7)),
                message: message,
                author: authorName
            )
        }
    }

    // MARK: - Log

    /// Get recent commits.
    public func log(limit: Int = 10, in repoURL: URL) throws -> [GitLogEntry] {
        try withRepo(at: repoURL) { repo in
            var walker: OpaquePointer?
            guard git_revwalk_new(&walker, repo) == 0, let walker else {
                throw gitError("Cannot create revwalk")
            }
            defer { git_revwalk_free(walker) }

            git_revwalk_sorting(walker, GIT_SORT_TIME.rawValue)

            // push_head can fail in detached HEAD / shallow-clone CI checkouts;
            // fall back to resolving HEAD manually via git_reference_name_to_id.
            if git_revwalk_push_head(walker) != 0 {
                var headOID = git_oid()
                if git_reference_name_to_id(&headOID, repo, "HEAD") == 0 {
                    git_revwalk_push(walker, &headOID)
                }
            }

            var entries: [GitLogEntry] = []
            var oid = git_oid()
            while git_revwalk_next(&oid, walker) == 0, entries.count < limit {
                var commit: OpaquePointer?
                guard git_commit_lookup(&commit, repo, &oid) == 0, let commit else { continue }
                defer { git_commit_free(commit) }

                var hashBuf = [CChar](repeating: 0, count: 41)
                git_oid_tostr(&hashBuf, 41, &oid)
                let hash = String(cString: hashBuf)
                let msg = git_commit_message(commit).map { String(cString: $0) } ?? ""
                let authorSig = git_commit_author(commit)
                let authorName = authorSig?.pointee.name.map { String(cString: $0) } ?? "unknown"
                let authorEmail = authorSig?.pointee.email.map { String(cString: $0) } ?? ""
                let time = git_commit_time(commit)

                entries.append(GitLogEntry(
                    hash: hash,
                    short: String(hash.prefix(7)),
                    message: msg.trimmingCharacters(in: .whitespacesAndNewlines),
                    author: authorName,
                    email: authorEmail,
                    timestamp: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(time)))
                ))
            }
            return entries
        }
    }

    // MARK: - Branch

    /// Get current branch name.
    public func currentBranch(in repoURL: URL) throws -> String? {
        try withRepo(at: repoURL) { repo in
            currentBranchName(repo)
        }
    }

    // MARK: - Tag

    /// Create a lightweight tag.
    public func tag(name: String, message: String? = nil, in repoURL: URL) throws {
        try withRepo(at: repoURL) { repo in
            var headRef: OpaquePointer?
            guard git_repository_head(&headRef, repo) == 0, let headRef else {
                throw gitError("Cannot get HEAD")
            }
            defer { git_reference_free(headRef) }

            let targetOid = git_reference_target(headRef)!
            var target: OpaquePointer?
            guard git_object_lookup(&target, repo, targetOid, GIT_OBJECT_COMMIT) == 0, let target else {
                throw gitError("Cannot lookup HEAD commit")
            }
            defer { git_object_free(target) }

            if let message {
                // Annotated tag
                var sig: UnsafeMutablePointer<git_signature>?
                git_signature_default(&sig, repo)
                if sig == nil { git_signature_now(&sig, "ARO", "aro@localhost") }
                defer { if let sig { git_signature_free(sig) } }

                var tagOid = git_oid()
                let rc = name.withCString { nameCStr in
                    message.withCString { msgCStr in
                        git_tag_create(&tagOid, repo, nameCStr, target, sig, msgCStr, 0)
                    }
                }
                guard rc == 0 else { throw gitError("Cannot create tag '\(name)'") }
            } else {
                // Lightweight tag
                var tagOid = git_oid()
                let rc = name.withCString { nameCStr in
                    git_tag_create_lightweight(&tagOid, repo, nameCStr, target, 0)
                }
                guard rc == 0 else { throw gitError("Cannot create tag '\(name)'") }
            }
        }
    }

    // MARK: - Clone

    /// Clone a repository.
    public func clone(url: String, to destination: URL, branch: String? = nil) throws -> GitCommitResult {
        lock.lock()
        defer { lock.unlock() }

        var opts = git_clone_options()
        git_clone_options_init(&opts, UInt32(GIT_CLONE_OPTIONS_VERSION))

        if let branch {
            // We need a stable C string pointer for the duration of the clone
            let branchCopy = strdup(branch)
            defer { free(branchCopy) }
            opts.checkout_branch = UnsafePointer(branchCopy)
        }

        var repo: OpaquePointer?
        let rc = url.withCString { urlCStr in
            destination.path.withCString { pathCStr in
                git_clone(&repo, urlCStr, pathCStr, &opts)
            }
        }
        guard rc == 0, let repo else { throw gitError("Cannot clone '\(url)'") }
        defer { git_repository_free(repo) }

        let hash = headCommitHash(repo) ?? ""
        let msg = "Cloned from \(url)"
        return GitCommitResult(hash: hash, short: String(hash.prefix(7)), message: msg, author: "")
    }

    // MARK: - Checkout

    /// Checkout a branch or ref.
    public func checkout(ref: String, in repoURL: URL) throws {
        try withRepo(at: repoURL) { repo in
            // Try as local branch first
            var reference: OpaquePointer?
            let refName = "refs/heads/\(ref)"
            var rc = refName.withCString { git_reference_lookup(&reference, repo, $0) }

            if rc != 0 {
                // Try as full ref
                rc = ref.withCString { git_reference_lookup(&reference, repo, $0) }
            }

            guard rc == 0, let reference else {
                throw gitError("Cannot find ref '\(ref)'")
            }
            defer { git_reference_free(reference) }

            let targetOid = git_reference_target(reference)!
            var commit: OpaquePointer?
            guard git_commit_lookup(&commit, repo, targetOid) == 0, let commit else {
                throw gitError("Cannot lookup commit for '\(ref)'")
            }
            defer { git_commit_free(commit) }

            var tree: OpaquePointer?
            guard git_commit_tree(&tree, commit) == 0, let tree else {
                throw gitError("Cannot get tree for '\(ref)'")
            }
            defer { git_tree_free(tree) }

            var checkoutOpts = git_checkout_options()
            git_checkout_options_init(&checkoutOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
            checkoutOpts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue

            guard git_checkout_tree(repo, tree, &checkoutOpts) == 0 else {
                throw gitError("Cannot checkout '\(ref)'")
            }

            // Update HEAD
            refName.withCString { git_repository_set_head(repo, $0) }
        }
    }

    // MARK: - Private helpers

    private func currentBranchName(_ repo: OpaquePointer) -> String? {
        var headRef: OpaquePointer?
        guard git_repository_head(&headRef, repo) == 0, let headRef else { return nil }
        defer { git_reference_free(headRef) }
        guard git_reference_is_branch(headRef) != 0 else { return nil }
        var name: UnsafePointer<CChar>?
        guard git_branch_name(&name, headRef) == 0, let name else { return nil }
        return String(cString: name)
    }

    private func headCommitHash(_ repo: OpaquePointer) -> String? {
        var headRef: OpaquePointer?
        guard git_repository_head(&headRef, repo) == 0, let headRef else { return nil }
        defer { git_reference_free(headRef) }
        guard let oid = git_reference_target(headRef) else { return nil }
        var buf = [CChar](repeating: 0, count: 41)
        git_oid_tostr(&buf, 41, oid)
        return String(cString: buf)
    }

    private func gitError(_ context: String) -> GitServiceError {
        let err = git_error_last()
        if let err, let msg = err.pointee.message {
            return .operationFailed(context: context, detail: String(cString: msg))
        }
        return .operationFailed(context: context, detail: "unknown error")
    }
}

// MARK: - Result Types

public struct GitStatus: Sendable {
    public let branch: String?
    public let commit: String?
    public let clean: Bool
    public let files: [[String: String]]

    public var asDictionary: [String: any Sendable] {
        var dict: [String: any Sendable] = [
            "clean": clean,
            "files": files.map { $0 as [String: any Sendable] },
        ]
        if let branch { dict["branch"] = branch }
        if let commit { dict["commit"] = commit }
        return dict
    }
}

public struct GitCommitResult: Sendable {
    public let hash: String
    public let short: String
    public let message: String
    public let author: String

    public var asDictionary: [String: any Sendable] {
        ["hash": hash, "short": short, "message": message, "author": author]
    }
}

public struct GitLogEntry: Sendable {
    public let hash: String
    public let short: String
    public let message: String
    public let author: String
    public let email: String
    public let timestamp: String

    public var asDictionary: [String: any Sendable] {
        ["hash": hash, "short": short, "message": message,
         "author": author, "email": email, "timestamp": timestamp]
    }
}

// MARK: - Errors

public enum GitServiceError: Error, Sendable, CustomStringConvertible {
    case notARepository(String)
    case operationFailed(context: String, detail: String)

    public var description: String {
        switch self {
        case .notARepository(let path):
            return "Not a Git repository: \(path)"
        case .operationFailed(let ctx, let detail):
            return "Git \(ctx): \(detail)"
        }
    }
}

#endif // !os(Windows)
