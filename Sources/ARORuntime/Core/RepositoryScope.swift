// ============================================================
// RepositoryScope.swift
// ARO Runtime — who a repository belongs to
// ARO-0094, GitLab #885
// ============================================================
//
// A repository is application-scoped, which is right for a catalogue and wrong
// for a shopping cart. `Declare the <cart-repository> with { scope: session }.`
// says which, once, where the repository is declared — so no statement has to
// restate it and none can disagree with the others.
//
// There are two caller scopes rather than one, and the distinction is a
// security property, not tidiness:
//
//   * `session` is an *identity*. It outlives a connection, survives reconnects
//     and parallel requests, and can be revoked.
//   * `connection` is a *transport lifetime*. It lasts as long as the socket and
//     identifies nobody.
//
// A TCP peer has the second and not the first: anyone who can open a socket gets
// a connection, the protocol carries no credentials, and treating a connection
// id as an identity would let an unauthenticated peer read a logged-in user's
// data. Keeping them as two words is what makes that hard to write by accident.

import Foundation

/// Who a repository's contents belong to.
public enum RepositoryScope: String, Sendable, CaseIterable {

    /// The whole program — every caller shares one repository. The default, and
    /// what every repository was before ARO-0094.
    case application

    /// One authenticated caller, across connections and requests.
    case session

    /// One transport connection, identifying nobody.
    case connection

    /// Parse the value of `scope:` in a `Declare` statement.
    public static func parse(_ raw: String) -> RepositoryScope? {
        RepositoryScope(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Whether resolving this scope needs to know who the caller is.
    public var needsCaller: Bool { self != .application }

    /// The names a diagnostic can suggest.
    public static var allNames: String {
        allCases.map(\.rawValue).sorted().joined(separator: ", ")
    }
}

/// Which caller the statement currently being executed belongs to.
///
/// Built by whichever transport accepted the work — an HTTP request from its
/// session cookie, a WebSocket frame from the session resolved at upgrade, a
/// socket event from the connection. `none` is not "anonymous": it is "there is
/// no caller here at all", which is the case in `Application-Start`, in a file
/// watcher, and in `aro run` with no server.
public enum CallerIdentity: Sendable, Equatable {
    case none
    case connection(id: String)
    case session(id: String, connection: String?)

    /// The key this identity contributes to a repository's storage partition.
    ///
    /// Empty for `application`, so an application-scoped repository keys
    /// exactly as it did before ARO-0094 and nothing about existing storage
    /// moves.
    public func storageKey(for scope: RepositoryScope) -> String? {
        switch scope {
        case .application:
            return ""
        case .session:
            if case .session(let id, _) = self { return "session:\(id)" }
            return nil
        case .connection:
            switch self {
            case .connection(let id):            return "conn:\(id)"
            case .session(_, .some(let conn)):   return "conn:\(conn)"
            default:                             return nil
            }
        }
    }

    /// How to describe this caller in an error.
    public var describedForError: String {
        switch self {
        case .none:                  return "this feature set has no caller"
        case .connection:            return "this connection has no session"
        case .session:               return "this caller has no connection"
        }
    }
}

/// The scopes an application has declared, by repository name.
///
/// Populated by `Declare` at startup and read on every repository statement, so
/// it is a lock-guarded singleton rather than something threaded through every
/// call site. Declaration happens once in `Application-Start`; reads are hot.
public final class RepositoryScopeRegistry: @unchecked Sendable {

    public static let shared = RepositoryScopeRegistry()

    private let lock = NSLock()
    private var scopes: [String: RepositoryScope] = [:]

    public init() {}

    /// Record a repository's scope.
    ///
    /// Declaring the same repository twice with *different* scopes is refused:
    /// one of the two statements is wrong, and picking either silently would
    /// make the wrong one look correct.
    @discardableResult
    public func declare(_ repository: String, scope: RepositoryScope) -> Result<Void, RepositoryScopeError> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = scopes[repository], existing != scope {
            return .failure(.conflictingDeclaration(
                repository: repository, existing: existing, attempted: scope))
        }
        scopes[repository] = scope
        return .success(())
    }

    /// A repository's declared scope, or `.application` if it was never
    /// declared — which is what every repository was before ARO-0094.
    public func scope(of repository: String) -> RepositoryScope {
        lock.lock()
        defer { lock.unlock() }
        return scopes[repository] ?? .application
    }

    /// Whether this repository was declared at all. Used by diagnostics that
    /// want to distinguish "declared application" from "never mentioned".
    public func isDeclared(_ repository: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return scopes[repository] != nil
    }

    /// Every declaration, for `aro check` and for tests.
    public func allDeclarations() -> [String: RepositoryScope] {
        lock.lock()
        defer { lock.unlock() }
        return scopes
    }

    /// Forget everything. Tests only — a process has one application.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        scopes.removeAll()
    }

    // MARK: - Resolution

    /// The storage partition for `repository`, given who is calling.
    ///
    /// Fails rather than falling back. A session-scoped repository read with no
    /// session must not quietly return the application-wide one: that turns a
    /// missing session into a cross-caller data leak that no test would catch,
    /// and an empty result would be just as wrong in the other direction —
    /// `Store` would write somewhere nobody reads.
    public func resolve(repository: String,
                        caller: CallerIdentity) -> Result<String, RepositoryScopeError> {
        let scope = self.scope(of: repository)
        guard let key = caller.storageKey(for: scope) else {
            return .failure(.unresolvable(repository: repository, scope: scope, caller: caller))
        }
        return .success(key)
    }
}

/// Why a repository's scope could not be used.
public enum RepositoryScopeError: Error, Equatable, CustomStringConvertible {

    case unresolvable(repository: String, scope: RepositoryScope, caller: CallerIdentity)
    case conflictingDeclaration(repository: String,
                                existing: RepositoryScope,
                                attempted: RepositoryScope)
    case unknownScope(repository: String, raw: String)

    public var description: String {
        switch self {
        case .unresolvable(let repository, let scope, let caller):
            return "\(repository) is \(scope.rawValue)-scoped and \(caller.describedForError)"
        case .conflictingDeclaration(let repository, let existing, let attempted):
            return "\(repository) is already declared \(existing.rawValue)-scoped; "
                 + "cannot redeclare it as \(attempted.rawValue)"
        case .unknownScope(let repository, let raw):
            return "'\(raw)' is not a scope for \(repository) (\(RepositoryScope.allNames))"
        }
    }
}
