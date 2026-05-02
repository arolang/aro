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
