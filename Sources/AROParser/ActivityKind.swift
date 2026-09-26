// ============================================================
// ActivityKind.swift
// AROParser — what kind of handler a business activity names
// GitLab #724
// ============================================================
//
// A feature set's business activity says how it is triggered, and six places
// used to work that out for themselves, each with its own substring tests:
// `AnalyzedProgram.init`, `FeatureGraph`, `EventAnalyzer.extractEventType`,
// `REPLSession.domainHandlerEventType`, `LLVMCodeGenerator.registerEventHandlers`
// and the LSP's code-action list. They did not agree.
//
// Two disagreements were live bugs rather than untidiness:
//
//   * `"WebSocket Event Handler"` *contains* `"Socket Event Handler"`. The code
//     generator knew, and ordered its checks accordingly; `AnalyzedProgram`
//     did not, and filed every WebSocket handler under both kinds.
//   * `EventAnalyzer` excluded Socket and File handlers but not WebSocket,
//     KeyPress, StateTransition, StateObserver or NotificationSent — so it
//     reported a domain event named `"WebSocket Event"`, and four more like it.
//
// The name-based dispatch bugs (#570, #571 for file handlers, and the socket
// and WebSocket equivalents) had to be fixed one classifier at a time for the
// same reason.
//
// This is the one parser. The "Business Activity Pattern" table in CLAUDE.md
// is its specification, and `ActivityKindTests` pins the orderings that the
// substring tests get wrong when written by hand.

import Foundation

/// How a feature set is triggered, read from its business activity.
public enum ActivityKind: Equatable, Sendable {

    /// `Socket Event Handler` — a TCP socket connect/data/disconnect.
    case socketEvent

    /// `WebSocket Event Handler`. Checked before `socketEvent`, because the
    /// name contains it.
    case webSocketEvent

    /// `File Event Handler` — a watched path changed.
    case fileEvent

    /// `KeyPress Handler` — terminal input.
    case keyPress

    /// `StateTransition Handler` — ARO-0022 state guards.
    case stateTransition

    /// `… StateObserver<from_to>` — ARO-0022.
    case stateObserver

    /// `NotificationSent Handler`.
    case notification

    /// `<name>-repository Observer` — a repository changed.
    case repositoryObserver(repository: String)

    /// `<name>-repository Evicted Handler`.
    case repositoryEviction(repository: String)

    /// `… Watch: …` — a watch expression.
    case watch

    /// `Application-End` (Success or Error).
    case applicationEnd

    /// `Action` — callable as `Application.<Name>` (ARO-0081).
    case userAction

    /// `{EventName} Handler` — a domain event emitted by `Emit`.
    case domainEvent(name: String)

    /// Anything else: an OpenAPI `operationId`, or plain documentation.
    case plain

    // MARK: - Parsing

    /// Classify a business activity.
    ///
    /// Order is the whole point. `webSocketEvent` is tested before
    /// `socketEvent`, and every service-bound kind before `domainEvent`, so a
    /// `WebSocket Event Handler` is not also read as a socket handler or as a
    /// domain event called "WebSocket Event".
    public static func parse(_ activity: String) -> ActivityKind {
        // A watch expression can carry any of the words below inside it.
        if activity.contains(" Watch:") { return .watch }

        if activity.contains("Application-End") { return .applicationEnd }

        // Before `socketEvent`: the name contains it.
        if activity.contains("WebSocket Event Handler") { return .webSocketEvent }
        if activity.contains("Socket Event Handler") { return .socketEvent }
        if activity.contains("File Event Handler") { return .fileEvent }
        if activity.contains("KeyPress Handler") { return .keyPress }
        if activity.contains("StateTransition Handler") { return .stateTransition }
        if activity.contains("StateObserver") { return .stateObserver }
        if activity.contains("NotificationSent Handler") { return .notification }

        // Repository kinds carry the repository's name, so they are parsed
        // rather than merely recognised. `Evicted Handler` is checked first:
        // it also ends in " Handler" and would otherwise read as a domain event.
        if activity.contains("-repository") {
            if let name = prefix(of: activity, before: " Evicted Handler") {
                return .repositoryEviction(repository: name)
            }
            if let name = prefix(of: activity, before: " Observer") {
                return .repositoryObserver(repository: name)
            }
        }

        if activity == "Action" || activity.hasPrefix("Action ") { return .userAction }

        // Split at the *first* " Handler", like the runtime, so a state-guarded
        // handler (`UserCreated Handler<status:paid>`, ARO-0022) resolves to
        // `UserCreated` and keeps its wire. The guard narrows which payloads
        // reach it, not which event.
        if let name = prefix(of: activity, before: " Handler") {
            return .domainEvent(name: name)
        }

        return .plain
    }

    private static func prefix(of activity: String, before marker: String) -> String? {
        guard let range = activity.range(of: marker) else { return nil }
        let head = String(activity[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? nil : head
    }

    // MARK: - Convenience

    /// The domain event this activity handles, or `nil` for every other kind.
    ///
    /// This is the question four of the six old classifiers were really
    /// asking, each with its own exclusion list.
    public var handledDomainEvent: String? {
        if case .domainEvent(let name) = self { return name }
        return nil
    }

    /// The repository this activity watches, whether for changes or evictions.
    public var observedRepository: String? {
        switch self {
        case .repositoryObserver(let r), .repositoryEviction(let r): return r
        default: return nil
        }
    }

    /// Whether a service wires this handler up, rather than the event bus.
    public var isServiceBound: Bool {
        switch self {
        case .socketEvent, .webSocketEvent, .fileEvent, .keyPress,
             .stateTransition, .stateObserver, .notification,
             .repositoryObserver, .repositoryEviction, .watch:
            return true
        case .applicationEnd, .userAction, .domainEvent, .plain:
            return false
        }
    }
}
