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

/// Creates a commit with staged changes.
///
/// ```aro
/// Commit the <result> to the <git> with "Fix authentication".
/// Commit the <result> to the <git> with { message: "feat: auth", author: "ARO <aro@example.com>" }.
/// ```
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
        context.emit(GitCommitEvent(hash: commitResult.hash, message: message, author: commitResult.author))

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
        context.emit(GitPullEvent(branch: branch))
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

        let branchName = branch ?? (try? git.currentBranch(in: repoURL)) ?? "unknown"
        let value: [String: any Sendable] = ["remote": remote, "branch": branchName]
        context.bind(result.base, value: value)
        context.emit(GitPushEvent(branch: branchName))
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
            destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(path)
        }

        let branch = expr["branch"] as? String
        let cloneResult = try git.clone(url: url, to: destination, branch: branch)

        let value = cloneResult.asDictionary
        context.bind(result.base, value: value)
        context.emit(GitCloneEvent(url: url, path: destination.path))
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
        context.emit(GitCheckoutEvent(ref: ref))
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
        context.emit(GitTagEvent(name: name))
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
