// ============================================================
// HandlerNameAnalyzer.swift
// AROParser — a handler whose name names no event
// GitLab #632
// ============================================================
//
// Socket and WebSocket handlers pick their event from a keyword in the feature
// set's *name*: "disconnect", "connect", "data"/"message"/"received". A name
// carrying none of them used to subscribe to nothing — the program compiled,
// `aro check` was silent, and the handler simply never ran.
//
// The runtime now subscribes such a handler to every event of its family,
// which is the safe reading: the alternative was firing never. But "every
// event" is rarely what the author meant, and a connect event carries no
// `<packet>`, so the handler will fail on two of the three. That is worth
// saying before the program runs rather than at three in the morning.

import Foundation

public enum HandlerNameAnalyzer {

    /// The keywords a socket-family handler's name is read for.
    public static let socketKeywords = ["disconnect", "connect", "data", "message", "received"]

    /// Report socket and WebSocket handlers whose name names no event.
    public static func check(_ program: Program, diagnostics: DiagnosticCollector) {
        for featureSet in program.featureSets {
            let kind = ActivityKind.parse(featureSet.businessActivity)
            let family: String
            switch kind {
            case .socketEvent:    family = "Socket"
            case .webSocketEvent: family = "WebSocket"
            default:              continue
            }

            let name = featureSet.name.lowercased()
            guard !socketKeywords.contains(where: { name.contains($0) }) else { continue }

            diagnostics.add(Diagnostic(
                severity: .warning,
                message: "\(featureSet.name) is a \(family) Event Handler, but its name says "
                       + "which event it handles",
                location: featureSet.span.start,
                hints: [
                    "The event is chosen from the name: connect, disconnect, "
                    + "or data / message / received",
                    "As written it subscribes to all of them, so it runs for "
                    + "connects and disconnects too — where there is no <packet> to read",
                    "Rename it, for example \"Handle \(featureSet.name) Data\""
                ]))
        }
    }
}
