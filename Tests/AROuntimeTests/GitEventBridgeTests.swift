// ============================================================
// GitEventBridgeTests.swift
// ARO Runtime - Git events an ARO handler can observe (GitLab #588)
// ============================================================
//
// Every mutating Git action published a typed `RuntimeEvent`, and ARO-0080
// §Events documents all six with their payloads — but no feature set could
// observe them. `ExecutionEngine.registerDomainEventHandlers` subscribes on the
// *Swift* type `DomainEvent`, which is what `Emit` produces, and
// `GitCommitEvent` and friends are not `DomainEvent`s. The events went onto the
// bus and nothing could be written that received them.
//
// The event's own `eventType` is not even spellable as a business activity:
// `git.commit` contains a dot, and a dot there is a parse error.

import Foundation
import Testing
@testable import ARORuntime

@Suite("Git events are observable (GitLab #588)")
struct GitEventBridgeTests {

    // MARK: - The handler spelling

    @Test("A dotted event type becomes the PascalCase activity a handler uses")
    func handlerNames() {
        #expect(GitEventBridge.handlerName(forEventType: "git.commit") == "GitCommit")
        #expect(GitEventBridge.handlerName(forEventType: "git.push") == "GitPush")
        #expect(GitEventBridge.handlerName(forEventType: "git.pull") == "GitPull")
        #expect(GitEventBridge.handlerName(forEventType: "git.checkout") == "GitCheckout")
        #expect(GitEventBridge.handlerName(forEventType: "git.tag") == "GitTag")
        #expect(GitEventBridge.handlerName(forEventType: "git.clone") == "GitClone")
    }

    @Test("The handler name contains no dot, which a business activity cannot")
    func handlerNamesAreSpellable() {
        for eventType in ["git.commit", "git.push", "git.pull",
                          "git.checkout", "git.tag", "git.clone"] {
            let name = GitEventBridge.handlerName(forEventType: eventType)
            #expect(!name.contains("."), "\(name) is not spellable as an activity")
        }
    }

    // MARK: - Every event maps, with the payload ARO-0080 documents

    @Test("A commit carries hash, message and author")
    func commitPayload() throws {
        let event = try #require(GitEventBridge.domainEvent(
            for: GitCommitEvent(hash: "abc123", message: "feat: x", author: "Ada")))

        #expect(event.domainEventType == "GitCommit")
        #expect(event.payload["hash"] as? String == "abc123")
        #expect(event.payload["message"] as? String == "feat: x")
        #expect(event.payload["author"] as? String == "Ada")
    }

    @Test("Push and pull carry the branch")
    func branchPayloads() throws {
        let push = try #require(GitEventBridge.domainEvent(for: GitPushEvent(branch: "main")))
        #expect(push.domainEventType == "GitPush")
        #expect(push.payload["branch"] as? String == "main")

        let pull = try #require(GitEventBridge.domainEvent(for: GitPullEvent(branch: "dev")))
        #expect(pull.domainEventType == "GitPull")
        #expect(pull.payload["branch"] as? String == "dev")
    }

    @Test("Checkout carries the ref and tag carries the name")
    func refAndNamePayloads() throws {
        let checkout = try #require(GitEventBridge.domainEvent(
            for: GitCheckoutEvent(ref: "feature/new")))
        #expect(checkout.domainEventType == "GitCheckout")
        #expect(checkout.payload["ref"] as? String == "feature/new")

        let tag = try #require(GitEventBridge.domainEvent(for: GitTagEvent(name: "v1.0.0")))
        #expect(tag.domainEventType == "GitTag")
        #expect(tag.payload["name"] as? String == "v1.0.0")
    }

    @Test("Clone carries url and path")
    func clonePayload() throws {
        let event = try #require(GitEventBridge.domainEvent(
            for: GitCloneEvent(url: "https://example.com/r.git", path: "./r")))

        #expect(event.domainEventType == "GitClone")
        #expect(event.payload["url"] as? String == "https://example.com/r.git")
        #expect(event.payload["path"] as? String == "./r")
    }

    @Test("All six of ARO-0080's events map")
    func allSixMap() {
        let events: [any RuntimeEvent] = [
            GitCommitEvent(hash: "h", message: "m", author: "a"),
            GitPushEvent(branch: "b"),
            GitPullEvent(branch: "b"),
            GitCheckoutEvent(ref: "r"),
            GitTagEvent(name: "n"),
            GitCloneEvent(url: "u", path: "p"),
        ]
        for event in events {
            #expect(GitEventBridge.domainEvent(for: event) != nil,
                    "\(type(of: event)) has no handler-observable form")
        }
    }

    // MARK: - An unknown event is not given a half-populated payload

    @Test("An event the bridge does not know maps to nothing")
    func unknownEventIsNotBridged() {
        // Returning a DomainEvent with an empty payload would be worse than
        // returning none: a handler would fire and read nothing.
        struct Other: RuntimeEvent {
            static var eventType: String { "other.thing" }
            let timestamp = Date()
        }
        #expect(GitEventBridge.domainEvent(for: Other()) == nil)
    }

    // MARK: - The typed events are untouched

    @Test("The typed events keep their dotted routing names")
    func typedEventsUnchanged() {
        // Swift-side subscribers subscribe on these, so they must not move.
        #expect(GitCommitEvent.eventType == "git.commit")
        #expect(GitPushEvent.eventType == "git.push")
        #expect(GitPullEvent.eventType == "git.pull")
        #expect(GitCheckoutEvent.eventType == "git.checkout")
        #expect(GitTagEvent.eventType == "git.tag")
        #expect(GitCloneEvent.eventType == "git.clone")
    }

    @Test("A commit event still carries its own typed fields")
    func typedFieldsStillPresent() {
        let event = GitCommitEvent(hash: "abc", message: "m", author: "a")
        #expect(event.hash == "abc")
        #expect(event.message == "m")
        #expect(event.author == "a")
    }
}
