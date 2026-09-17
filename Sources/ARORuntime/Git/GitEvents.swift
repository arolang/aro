// ============================================================
// GitEvents.swift
// ARO Runtime - Git Event Types (ARO-0080)
// ============================================================

import Foundation

#if !os(Windows)

/// Event emitted when a commit is created
public struct GitCommitEvent: RuntimeEvent {
    public static var eventType: String { "git.commit" }
    public let timestamp: Date
    public let hash: String
    public let message: String
    public let author: String

    public init(hash: String, message: String, author: String) {
        self.timestamp = Date()
        self.hash = hash
        self.message = message
        self.author = author
    }
}

/// Event emitted when changes are pushed
public struct GitPushEvent: RuntimeEvent {
    public static var eventType: String { "git.push" }
    public let timestamp: Date
    public let branch: String

    public init(branch: String) {
        self.timestamp = Date()
        self.branch = branch
    }
}

/// Event emitted when changes are pulled
public struct GitPullEvent: RuntimeEvent {
    public static var eventType: String { "git.pull" }
    public let timestamp: Date
    public let branch: String?

    public init(branch: String?) {
        self.timestamp = Date()
        self.branch = branch
    }
}

/// Event emitted when a branch is checked out
public struct GitCheckoutEvent: RuntimeEvent {
    public static var eventType: String { "git.checkout" }
    public let timestamp: Date
    public let ref: String

    public init(ref: String) {
        self.timestamp = Date()
        self.ref = ref
    }
}

/// Event emitted when a tag is created
public struct GitTagEvent: RuntimeEvent {
    public static var eventType: String { "git.tag" }
    public let timestamp: Date
    public let name: String

    public init(name: String) {
        self.timestamp = Date()
        self.name = name
    }
}

/// Event emitted when a repository is cloned
public struct GitCloneEvent: RuntimeEvent {
    public static var eventType: String { "git.clone" }
    public let timestamp: Date
    public let url: String
    public let path: String

    public init(url: String, path: String) {
        self.timestamp = Date()
        self.url = url
        self.path = path
    }
}

#endif // !os(Windows)

// MARK: - Making Git events observable from ARO (GitLab #588)

/// The handler-spellable name and payload for each Git event.
///
/// Every mutating Git action published a typed `RuntimeEvent`, and ARO-0080
/// §Events documents all six with their payloads — but no feature set could
/// observe them. Handler registration subscribes on the *Swift* type
/// `DomainEvent`, which is what `Emit` produces, and `GitCommitEvent` and
/// friends are not `DomainEvent`s. The events went onto the bus and nothing
/// could be written that received them.
///
/// The event's own `eventType` is not even spellable as a business activity:
/// `git.commit` contains a dot, and a dot there is a parse error.
///
/// So each action now emits a `DomainEvent` alongside its typed event, named
/// the way every other handler is named — `GitCommit`, matching the PascalCase
/// convention — with the payload ARO-0080 already documents. The typed events
/// stay exactly as they were for Swift-side subscribers, and handler
/// registration is untouched, so none of the existing handlers are at risk.
public enum GitEventBridge {

    /// `GitCommit` for `git.commit`, and so on: the dotted routing name turned
    /// into the PascalCase activity a handler can be written against.
    public static func handlerName(forEventType eventType: String) -> String {
        // "git.commit" -> "GitCommit"
        eventType
            .split(separator: ".")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()
    }

    /// The `DomainEvent` an ARO handler can subscribe to for `event`.
    ///
    /// Returns `nil` for an event this bridge does not know, so a new typed
    /// event cannot silently acquire a half-populated payload.
    public static func domainEvent(for event: any RuntimeEvent) -> DomainEvent? {
        let payload: [String: any Sendable]
        let eventType: String

        switch event {
        case let commit as GitCommitEvent:
            eventType = GitCommitEvent.eventType
            payload = ["hash": commit.hash, "message": commit.message, "author": commit.author]
        case let push as GitPushEvent:
            eventType = GitPushEvent.eventType
            payload = ["branch": push.branch]
        case let pull as GitPullEvent:
            eventType = GitPullEvent.eventType
            payload = ["branch": pull.branch]
        case let checkout as GitCheckoutEvent:
            eventType = GitCheckoutEvent.eventType
            payload = ["ref": checkout.ref]
        case let tag as GitTagEvent:
            eventType = GitTagEvent.eventType
            payload = ["name": tag.name]
        case let clone as GitCloneEvent:
            eventType = GitCloneEvent.eventType
            payload = ["url": clone.url, "path": clone.path]
        default:
            return nil
        }

        return DomainEvent(eventType: handlerName(forEventType: eventType), payload: payload)
    }
}
