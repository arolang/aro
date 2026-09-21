// ============================================================
// ProjectMapActivity.swift
// SOLARO — the project map, while the program runs (#765)
// ============================================================
//
// The Project Map draws every feature set in the application and the
// wires between them: an `Emit` reaching its handlers, an
// `Application.<Name>` call reaching its action. It drew them
// statically. The canvas glows during a run, but it shows one file —
// and the interesting picture, an event leaving `createUser` and
// arriving at three handlers across three files, existed as a drawing
// and as a run, never as both at once. The book's §9 already promises
// that edges from `Emit` statements "animate when an event fires".
//
// The data was already being collected. `ConsoleProcess` stamps
// `lastExecutedAtPerFeatureSet[name] = now` for every record that names
// a feature set, which is what the canvas containers glow from. Nothing
// fed it to the map.
//
// These are the rules for turning those timestamps into a picture, kept
// away from the view so they can be tested against dates rather than
// inspected by eye.

import Foundation

/// How recently things ran, and what that should look like.
struct ProjectMapActivity: Equatable {

    /// How long a feature set stays lit after it last executed.
    ///
    /// Long enough to see at a glance in a burst, short enough that a
    /// map of a finished run settles rather than staying lit forever.
    static let glowDuration: TimeInterval = 1.2

    /// How long a wire stays animated after its target ran.
    ///
    /// Shorter than the node glow: the travelling pulse reads as the
    /// event *moving*, and a pulse that outlasts the arrival is a lie
    /// about what is happening.
    static let pulseDuration: TimeInterval = 0.8

    /// Last execution per feature-set name, as the console recorded it.
    var lastExecuted: [String: Date] = [:]

    /// Whether a program is running. A finished run leaves its final
    /// state on screen rather than fading it, because "what ran last"
    /// is still the useful thing to see.
    var isRunning: Bool = false

    /// 0 when cold, 1 immediately after executing, falling to 0 over
    /// `glowDuration`.
    ///
    /// Linear, not eased: a reader comparing two glowing nodes is
    /// judging "which ran more recently", and a curve distorts that.
    func glow(forFeatureSet name: String, now: Date) -> Double {
        intensity(since: lastExecuted[name], now: now,
                  over: Self.glowDuration)
    }

    /// How far a pulse has travelled along an edge, 0 to 1, or `nil`
    /// when that edge is not firing.
    ///
    /// The edge is driven by its *target*: an event's arrival is the
    /// moment the receiving feature set runs, and that is the record
    /// the runtime writes. The emitter having run at some earlier point
    /// says nothing about whether this particular wire carried
    /// anything.
    func pulseProgress(from source: String, to target: String,
                       now: Date) -> Double? {
        guard let arrived = lastExecuted[target] else { return nil }
        // An edge only fires if its source has run at all — otherwise a
        // handler triggered by something else would light every wire
        // pointing at it.
        guard let emitted = lastExecuted[source], emitted <= arrived else {
            return nil
        }
        let elapsed = now.timeIntervalSince(arrived)
        guard elapsed >= 0, elapsed < Self.pulseDuration else { return nil }
        return elapsed / Self.pulseDuration
    }

    /// Whether anything is lit right now. The view stops asking for
    /// animation frames when nothing is.
    func hasActivity(now: Date) -> Bool {
        guard isRunning || !lastExecuted.isEmpty else { return false }
        return lastExecuted.values.contains { date in
            now.timeIntervalSince(date) < Self.glowDuration
        }
    }

    private func intensity(since date: Date?, now: Date,
                           over duration: TimeInterval) -> Double {
        guard let date else { return 0 }
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= 0 else { return 1 }
        guard elapsed < duration else { return 0 }
        return 1 - (elapsed / duration)
    }
}
