// ============================================================
// GitActions.swift
// ARO Runtime - Git Action Implementations (ARO-0080)
// ============================================================

import Foundation
import AROParser

#if !os(Windows)

// MARK: - Stage Action

/// Stages files for commit in a Git repository.
///
/// ```aro
/// Stage the <files> to the <git> with ".".
/// Stage the <files> to the <git> with ["README.md", "src/main.aro"].
/// ```
public struct StageAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["stage"]
    public static let validPrepositions: Set<Preposition> = [.to, .for]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        let git = GitService.shared
        let repoURL = git.resolveRepoPath(resolveQualifier(object, context: context))

        // Get files to stage from expression/with clause
        let files: [String]
        if let expr = context.resolveAny("_expression_") {
            if let arr = expr as? [any Sendable] {
                files = arr.compactMap { $0 as? String }
            } else if let str = expr as? String {
                files = [str]
            } else {
                files = ["."]
            }
        } else {
            files = ["."]
        }

        try git.stage(files: files, in: repoURL)
        let value: [String: any Sendable] = ["staged": files, "count": files.count]
        context.bind(result.base, value: value)
        return value
    }
}

// MARK: - Commit Action (Git)

/// Creates a commit with staged changes — or writes a `.store` file.
///
/// ```aro
/// Commit the <result> to the <git> with "Fix authentication".
/// Commit the <result> to the <git> with { message: "feat: auth", author: "ARO <aro@example.com>" }.
///
/// Commit the <saved> to the <orders-repository>.   (* one store, now *)
/// Commit the <checkpoint> to the <stores>.         (* every writable store *)
/// ```
///
/// The two share a verb because they are the same act: taking what is in
/// memory and making it durable (ARO-0073 §5a, GitLab #863). The object says
/// which — `<git>` a repository of commits, a `*-repository` or `<stores>` the
/// file behind a seeded repository.
public struct GitCommitAction: ActionImplementation {
    public static let role: ActionRole = .export
    public static let verbs: Set<String> = ["commit"]
    public static let validPrepositions: Set<Preposition> = [.to, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        if let stores = try await Self.commitStores(result: result, object: object, context: context) {
            return stores
        }
        return try await gitCommit(result: result, object: object, context: context)
    }

    // MARK: - Store checkpoints (ARO-0073 §5a, GitLab #863)

    /// `Commit the <r> to the <stores>.` / `Commit the <r> to the <x-repository>.`
    ///
    /// Returns `nil` when the object is not a store target, so the Git path
    /// runs unchanged.
    static func commitStores(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> (any Sendable)? {
        let target = object.base
        let isAll = target == "stores" || target == "store"
        let isRepository = InMemoryRepositoryStorage.isRepositoryName(target)
        guard isAll || isRepository else { return nil }

        guard let service = StoreFlushRegistry.current else {
            // No writable `.store` file in this application. Saying so beats
            // reporting success for a write that could not have happened.
            throw ActionError.invalidInput(
                "Commit the <\(result.base)> to the <\(target)>: this application has no "
                + "writable .store file (ARO-0073 — chmod o+w the .store file)",
                received: target)
        }

        if isRepository, await !service.isWritable(repository: target) {
            throw ActionError.invalidInput(
                "Commit the <\(result.base)> to the <\(target)>: no writable .store file "
                + "backs that repository (ARO-0073 — chmod o+w the .store file)",
                received: target)
        }

        let checkpoint = try await service.checkpoint(repositories: isAll ? nil : [target])
        let record: [String: any Sendable] = [
            "repositories": checkpoint.repositories,
            "written": checkpoint.written,
            "items": checkpoint.items
        ]
        context.bind(result.base, value: record)
        return record
    }

    private func gitCommit(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        let git = GitService.shared
        let repoURL = git.resolveRepoPath(resolveQualifier(object, context: context))

        // Get commit message and optional author
        let message: String
        var author: String? = nil

        if let expr = context.resolveAny("_expression_") {
            if let dict = expr as? [String: any Sendable] {
                message = dict["message"] as? String ?? String(describing: expr)
                author = dict["author"] as? String
            } else if let str = expr as? String {
                message = str
            } else {
                message = String(describing: expr)
            }
        } else if let str: String = context.resolve(result.base) {
            message = str
        } else {
            message = "Commit from ARO"
        }

        let commitResult = try git.commit(message: message, author: author, in: repoURL)
        context.bind(result.base, value: commitResult.asDictionary)

        // Emit event
        let gitEvent = GitCommitEvent(hash: commitResult.hash, message: message, author: commitResult.author)
        context.emit(gitEvent)
        // Also as a DomainEvent, so an ARO handler can observe it:
        // handler registration subscribes on the Swift type `DomainEvent`,
        // which a typed Git event is not (GitLab #588).
        if let observable = GitEventBridge.domainEvent(for: gitEvent) {
            context.emit(observable)
        }

        return commitResult.asDictionary
    }
}

// MARK: - Pull Action

/// Fetches and merges remote changes.
///
/// ```aro
/// Pull the <updates> from the <git>.
/// ```
///
/// Note: Pull is not yet supported via libgit2 in this implementation.
/// Use `Execute the <result> with "git pull"` as a workaround.
public struct PullAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["pull"]
    public static let validPrepositions: Set<Preposition> = [.from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        let git = GitService.shared
        let repoURL = git.resolveRepoPath(resolveQualifier(object, context: context))
        let branch = try git.currentBranch(in: repoURL)

        // libgit2 pull is fetch+merge which is complex; shell out for now
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["pull"]
        process.currentDirectoryURL = repoURL
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let value: [String: any Sendable] = ["branch": branch ?? "unknown", "output": output]
        context.bind(result.base, value: value)
        let gitEvent = GitPullEvent(branch: branch)
        context.emit(gitEvent)
        // Also as a DomainEvent, so an ARO handler can observe it:
        // handler registration subscribes on the Swift type `DomainEvent`,
        // which a typed Git event is not (GitLab #588).
        if let observable = GitEventBridge.domainEvent(for: gitEvent) {
            context.emit(observable)
        }
        return value
    }
}

// MARK: - Push Action

/// Pushes commits to the remote repository.
///
/// ```aro
/// Push the <result> to the <git>.
/// Push the <result> to the <git> with { remote: "origin", branch: "main" }.
/// ```
public struct PushAction: ActionImplementation {
    public static let role: ActionRole = .export
    public static let verbs: Set<String> = ["push"]
    public static let validPrepositions: Set<Preposition> = [.to, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        let git = GitService.shared
        let repoURL = git.resolveRepoPath(resolveQualifier(object, context: context))

        var remote = "origin"
        var branch: String? = nil

        if let expr = context.resolveAny("_expression_") as? [String: any Sendable] {
            remote = expr["remote"] as? String ?? "origin"
            branch = expr["branch"] as? String
        }

        // libgit2 push requires credential callbacks; shell out for simplicity
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        var args = ["push", remote]
        if let branch { args.append(branch) }
        process.arguments = args
        process.currentDirectoryURL = repoURL
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        // A detached HEAD or a repository with no commits yet has no current
        // branch; "unknown" is the honest answer and the push already happened.
        let branchName = branch ?? (try? git.currentBranch(in: repoURL)) ?? "unknown"
        let value: [String: any Sendable] = ["remote": remote, "branch": branchName]
        context.bind(result.base, value: value)
        let gitEvent = GitPushEvent(branch: branchName)
        context.emit(gitEvent)
        // Also as a DomainEvent, so an ARO handler can observe it:
        // handler registration subscribes on the Swift type `DomainEvent`,
        // which a typed Git event is not (GitLab #588).
        if let observable = GitEventBridge.domainEvent(for: gitEvent) {
            context.emit(observable)
        }
        return value
    }
}

// MARK: - Clone Action

/// Clones a remote Git repository.
///
/// ```aro
/// Clone the <repo> from the <git> with { url: "https://github.com/user/repo.git", path: "./cloned" }.
/// ```
public struct CloneAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["clone"]
    public static let validPrepositions: Set<Preposition> = [.from, .with, .to]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        let git = GitService.shared

        guard let expr = context.resolveAny("_expression_") as? [String: any Sendable],
              let url = expr["url"] as? String,
              let path = expr["path"] as? String else {
            throw ActionError.runtimeError("Clone requires { url: \"...\", path: \"...\" }")
        }

        let destination: URL
        if path.hasPrefix("/") {
            destination = URL(fileURLWithPath: path)
        } else {
            destination = URL(fileURLWithPath: AROWorkingDirectory.base)
                .appendingPathComponent(path)
        }

        let branch = expr["branch"] as? String
        let username = expr["username"] as? String
        let token = expr["token"] as? String
        let cloneResult = try git.clone(
            url: url,
            to: destination,
            branch: branch,
            username: username,
            token: token
        )

        let value = cloneResult.asDictionary
        context.bind(result.base, value: value)
        let gitEvent = GitCloneEvent(url: url, path: destination.path)
        context.emit(gitEvent)
        // Also as a DomainEvent, so an ARO handler can observe it:
        // handler registration subscribes on the Swift type `DomainEvent`,
        // which a typed Git event is not (GitLab #588).
        if let observable = GitEventBridge.domainEvent(for: gitEvent) {
            context.emit(observable)
        }
        return value
    }
}

// MARK: - Checkout Action (Git)

/// Switches branches or restores files.
///
/// ```aro
/// Checkout the <branch> from the <git> with "feature/new".
/// ```
public struct GitCheckoutAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["checkout"]
    public static let validPrepositions: Set<Preposition> = [.from, .to, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        let git = GitService.shared
        let repoURL = git.resolveRepoPath(resolveQualifier(object, context: context))

        guard let expr = context.resolveAny("_expression_"),
              let ref = expr as? String else {
            throw ActionError.runtimeError("Checkout requires a branch or ref name")
        }

        try git.checkout(ref: ref, in: repoURL)
        let value: [String: any Sendable] = ["ref": ref]
        context.bind(result.base, value: value)
        let gitEvent = GitCheckoutEvent(ref: ref)
        context.emit(gitEvent)
        // Also as a DomainEvent, so an ARO handler can observe it:
        // handler registration subscribes on the Swift type `DomainEvent`,
        // which a typed Git event is not (GitLab #588).
        if let observable = GitEventBridge.domainEvent(for: gitEvent) {
            context.emit(observable)
        }
        return value
    }
}

// MARK: - Tag Action

/// Creates a Git tag.
///
/// ```aro
/// Tag the <release> for the <git> with "v1.0.0".
/// Tag the <release> for the <git> with { name: "v1.0.0", message: "Release 1.0" }.
/// ```
public struct TagAction: ActionImplementation {
    public static let role: ActionRole = .export
    public static let verbs: Set<String> = ["tag"]
    public static let validPrepositions: Set<Preposition> = [.for, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        let git = GitService.shared
        let repoURL = git.resolveRepoPath(resolveQualifier(object, context: context))

        let name: String
        var message: String? = nil

        if let expr = context.resolveAny("_expression_") {
            if let dict = expr as? [String: any Sendable] {
                guard let n = dict["name"] as? String else {
                    throw ActionError.runtimeError("Tag requires a 'name' field")
                }
                name = n
                message = dict["message"] as? String
            } else if let str = expr as? String {
                name = str
            } else {
                throw ActionError.runtimeError("Tag requires a name string or { name, message }")
            }
        } else {
            throw ActionError.runtimeError("Tag requires a name")
        }

        try git.tag(name: name, message: message, in: repoURL)
        let value: [String: any Sendable] = ["name": name]
        context.bind(result.base, value: value)
        let gitEvent = GitTagEvent(name: name)
        context.emit(gitEvent)
        // Also as a DomainEvent, so an ARO handler can observe it:
        // handler registration subscribes on the Swift type `DomainEvent`,
        // which a typed Git event is not (GitLab #588).
        if let observable = GitEventBridge.domainEvent(for: gitEvent) {
            context.emit(observable)
        }
        return value
    }
}

// MARK: - Helpers

/// Resolve the qualifier of a `git` object to get the repo path.
/// Returns nil (meaning cwd) when the object is bare `<git>`.
private func resolveQualifier(_ object: ObjectDescriptor, context: ExecutionContext) -> String? {
    // If the object is "git" and has a qualifier (specifier), use it
    if object.base.lowercased() == "git" {
        if let first = object.specifiers.first, !first.isEmpty {
            // Could be a literal path or a variable reference
            let cleaned = first.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if let resolved: String = context.resolve(cleaned) {
                return resolved
            }
            return cleaned
        }
    }
    return nil
}

#endif // !os(Windows)
