// ============================================================
// SolaroDiagnostics.swift
// SOLARO — a place for failures that used to vanish (#755)
// ============================================================
//
// CLAUDE.md's rule is that a `try?` needs a documented reason, and that a
// fallback which loses data must at least warn on stderr.
// `WorkspaceController.writeToDisk` already models the full pattern:
// record the failure, log it once, show it.
//
// Most of the offenders here are not editor files, so they have no
// business in the editor's save banner — a layout sidecar that would not
// write, the recent-projects list, the try-it-out history. They are all
// small, all best-effort, and all silently lost work when they failed.
//
// This is their shared surface: one line on stderr, and the most recent
// message kept for the status bar so the user has some way of knowing the
// app could not write something. It is deliberately not modal. Losing the
// positions of some canvas nodes should not interrupt anyone; it should
// also not be a secret.

import Foundation

/// Non-fatal failures worth telling somebody about.
@MainActor
@Observable
final class SolaroDiagnostics {

    /// The one everybody reports to. A single instance because these
    /// failures are about the app's own support files, not about a
    /// particular project window.
    static let shared = SolaroDiagnostics()

    struct Warning: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let at: Date
    }

    /// The most recent warning, or `nil` once it has been dismissed.
    private(set) var latest: Warning?

    /// Every distinct message seen this session, so the stderr log does
    /// not repeat itself once a second while a disk stays full.
    @ObservationIgnored private var logged: Set<String> = []

    private init() {}

    /// Record a failure that cost the user something small.
    ///
    /// `what` names what could not be saved, in the user's terms rather
    /// than the API's — "canvas layout", not "sidecar".
    func report(_ what: String, error: any Error) {
        record("Could not save \(what): "
               + (error as NSError).localizedDescription)
    }

    func dismiss() {
        latest = nil
    }

    /// `report` from wherever you are.
    ///
    /// Several of these failures happen in plain static helpers that have
    /// no actor — the recent-projects list, for one — so the description
    /// is taken here, while the error is still in hand, and only a string
    /// crosses to the main actor.
    nonisolated static func warn(_ what: String, error: any Error) {
        let detail = (error as NSError).localizedDescription
        Task { @MainActor in
            shared.record("Could not save \(what): \(detail)")
        }
    }

    fileprivate func record(_ message: String) {
        latest = Warning(message: message, at: Date())
        if logged.insert(message).inserted {
            FileHandle.standardError.write(
                Data("[SOLARO] Warning: \(message)\n".utf8))
        }
    }
}
