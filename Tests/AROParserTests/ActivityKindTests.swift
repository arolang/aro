// ============================================================
// ActivityKindTests.swift
// AROParser — one classifier, and the orderings it has to get right
// GitLab #724
// ============================================================
//
// Six places worked out what kind of handler a business activity names, each
// with its own substring tests, and they disagreed. These tests pin the two
// disagreements that were live bugs, plus the orderings a seventh hand-written
// classifier would get wrong in the same way.

import Testing
@testable import AROParser

@Suite("Business activity classification (#724)")
struct ActivityKindTests {

    // MARK: - The substring traps

    @Test("A WebSocket handler is not also a socket handler")
    func webSocketIsNotSocket() {
        // `"WebSocket Event Handler"` contains `"Socket Event Handler"`.
        // `AnalyzedProgram` filed every WebSocket handler under both kinds;
        // the code generator avoided it only by ordering its checks and saying
        // so in a comment.
        #expect(ActivityKind.parse("WebSocket Event Handler") == .webSocketEvent)
        #expect(ActivityKind.parse("Socket Event Handler") == .socketEvent)
    }

    @Test("A service-bound handler is never a domain event")
    func serviceBoundHandlersAreNotDomainEvents() {
        // `EventAnalyzer` excluded Socket, File and Application-End but not
        // these — so it reported a domain event named "WebSocket Event",
        // and one for each of the others.
        for activity in ["WebSocket Event Handler",
                         "Socket Event Handler",
                         "File Event Handler",
                         "KeyPress Handler",
                         "StateTransition Handler",
                         "NotificationSent Handler"] {
            #expect(ActivityKind.parse(activity).handledDomainEvent == nil,
                    "\(activity) read as a domain event")
        }
    }

    @Test("An eviction handler is not a domain event called '<repo> Evicted'")
    func evictionIsNotADomainEvent() {
        // It ends in " Handler" like any domain handler, so it has to be
        // recognised before the generic split.
        let kind = ActivityKind.parse("session-repository Evicted Handler")
        #expect(kind == .repositoryEviction(repository: "session-repository"))
        #expect(kind.handledDomainEvent == nil)
    }

    // MARK: - What each kind carries

    @Test("A domain handler yields its event name")
    func domainEventName() {
        #expect(ActivityKind.parse("UserCreated Handler") == .domainEvent(name: "UserCreated"))
    }

    @Test("A state-guarded handler keeps the event, not the guard")
    func stateGuardedHandlerKeepsItsEvent() {
        // ARO-0022: the guard narrows which payloads reach the handler, not
        // which event it is wired to, so the split is at the *first* " Handler".
        #expect(ActivityKind.parse("UserCreated Handler<status:paid>")
                == .domainEvent(name: "UserCreated"))
    }

    @Test("A repository observer yields its repository")
    func repositoryObserverName() {
        #expect(ActivityKind.parse("user-repository Observer")
                == .repositoryObserver(repository: "user-repository"))
        #expect(ActivityKind.parse("user-repository Observer").observedRepository
                == "user-repository")
    }

    @Test("An observer without -repository is not a repository observer")
    func plainObserverIsNotARepository() {
        // The `-repository` test mirrors what the runtime actually subscribes.
        #expect(ActivityKind.parse("Audit Observer") == .plain)
    }

    @Test("A watch activity wins over words inside its expression")
    func watchWinsOverItsContents() {
        // A watch expression can quote anything, including the words that name
        // another kind.
        #expect(ActivityKind.parse("Inventory Watch: File Event Handler") == .watch)
    }

    @Test("Application-End is not an event handler")
    func applicationEndIsItsOwnKind() {
        #expect(ActivityKind.parse("Application-End") == .applicationEnd)
        #expect(ActivityKind.parse("Application-End").handledDomainEvent == nil)
    }

    @Test("A user-defined action is its own kind, not an operationId")
    func userActionKind() {
        #expect(ActivityKind.parse("Action") == .userAction)
        #expect(ActivityKind.parse("Action takes <number>") == .userAction)
    }

    @Test("An operationId is plain")
    func operationIdIsPlain() {
        #expect(ActivityKind.parse("listUsers") == .plain)
        #expect(ActivityKind.parse("User API") == .plain)
    }

    // MARK: - The property the six consumers rely on

    @Test("Exactly the service-bound kinds report isServiceBound")
    func serviceBoundIsExhaustive() {
        // The REPL subscribes a handler only when a service is not going to,
        // so this split is the one that decides whether a definition goes live
        // in an interactive session.
        for activity in ["Socket Event Handler", "WebSocket Event Handler",
                         "File Event Handler", "KeyPress Handler",
                         "StateTransition Handler", "NotificationSent Handler",
                         "user-repository Observer", "Inventory Watch: x"] {
            #expect(ActivityKind.parse(activity).isServiceBound, "\(activity)")
        }
        for activity in ["UserCreated Handler", "listUsers", "Action", "Application-End"] {
            #expect(!ActivityKind.parse(activity).isServiceBound, "\(activity)")
        }
    }
}
