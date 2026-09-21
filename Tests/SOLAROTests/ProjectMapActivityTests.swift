// ============================================================
// ProjectMapActivityTests.swift
// SOLARO — the project map, while the program runs (GitLab #765)
// ============================================================
//
// The Project Map drew the application's wires statically. The canvas
// glowed during a run but shows one file, so the interesting picture —
// an event leaving createUser and arriving at three handlers across
// three files — existed as a drawing and as a run, never as both.
//
// The timestamps were already being collected. These are the rules for
// turning them into a picture, which is why they live away from the
// view: they can be checked against dates rather than by eye.

import Testing
import Foundation
@testable import SOLARO

@Suite("Project map activity")
struct ProjectMapActivityTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func aFeatureSetThatJustRanGlowsFully() {
        let activity = ProjectMapActivity(
            lastExecuted: ["createUser": now], isRunning: true)
        #expect(activity.glow(forFeatureSet: "createUser", now: now) == 1)
    }

    @Test func theGlowFadesLinearly() {
        let activity = ProjectMapActivity(
            lastExecuted: ["createUser": now], isRunning: true)
        let half = now.addingTimeInterval(ProjectMapActivity.glowDuration / 2)
        let glow = activity.glow(forFeatureSet: "createUser", now: half)
        #expect(abs(glow - 0.5) < 0.001)
        // Linear, not eased: a reader comparing two glowing nodes is
        // judging which ran more recently, and a curve distorts that.
        let quarter = now.addingTimeInterval(ProjectMapActivity.glowDuration / 4)
        #expect(abs(activity.glow(forFeatureSet: "createUser", now: quarter)
                    - 0.75) < 0.001)
    }

    @Test func aFeatureSetThatNeverRanDoesNotGlow() {
        let activity = ProjectMapActivity(lastExecuted: [:], isRunning: true)
        #expect(activity.glow(forFeatureSet: "createUser", now: now) == 0)
    }

    @Test func theGlowExpires() {
        let activity = ProjectMapActivity(
            lastExecuted: ["createUser": now], isRunning: true)
        let later = now.addingTimeInterval(
            ProjectMapActivity.glowDuration + 0.1)
        #expect(activity.glow(forFeatureSet: "createUser", now: later) == 0)
    }

    // MARK: - Wires

    @Test func aWireFiresWhenItsTargetRunsAfterItsSource() {
        let activity = ProjectMapActivity(lastExecuted: [
            "createUser": now.addingTimeInterval(-0.2),
            "Send Welcome Email": now,
        ], isRunning: true)
        let progress = activity.pulseProgress(
            from: "createUser", to: "Send Welcome Email", now: now)
        #expect(progress == 0)
    }

    @Test func thePulseTravelsAlongTheWire() {
        let activity = ProjectMapActivity(lastExecuted: [
            "createUser": now.addingTimeInterval(-0.2),
            "Send Welcome Email": now,
        ], isRunning: true)
        let half = now.addingTimeInterval(ProjectMapActivity.pulseDuration / 2)
        let progress = activity.pulseProgress(
            from: "createUser", to: "Send Welcome Email", now: half)
        #expect(progress != nil)
        #expect(abs((progress ?? 0) - 0.5) < 0.001)
    }

    @Test func aWireWhoseSourceNeverRanDoesNotFire() {
        // Otherwise a handler triggered by something else would light
        // every wire pointing at it, which is a picture of nothing.
        let activity = ProjectMapActivity(
            lastExecuted: ["Send Welcome Email": now], isRunning: true)
        #expect(activity.pulseProgress(from: "createUser",
                                       to: "Send Welcome Email",
                                       now: now) == nil)
    }

    @Test func aWireWhoseSourceRanAfterwardsDoesNotFire() {
        // The source running later cannot have caused this arrival.
        let activity = ProjectMapActivity(lastExecuted: [
            "createUser": now,
            "Send Welcome Email": now.addingTimeInterval(-0.5),
        ], isRunning: true)
        #expect(activity.pulseProgress(from: "createUser",
                                       to: "Send Welcome Email",
                                       now: now) == nil)
    }

    @Test func thePulseIsShorterThanTheGlow() {
        // The travelling dot reads as the event moving; a pulse that
        // outlasts the arrival is a lie about what is happening.
        #expect(ProjectMapActivity.pulseDuration
                < ProjectMapActivity.glowDuration)
    }

    @Test func thePulseExpires() {
        let activity = ProjectMapActivity(lastExecuted: [
            "createUser": now.addingTimeInterval(-0.2),
            "Send Welcome Email": now,
        ], isRunning: true)
        let later = now.addingTimeInterval(
            ProjectMapActivity.pulseDuration + 0.1)
        #expect(activity.pulseProgress(from: "createUser",
                                       to: "Send Welcome Email",
                                       now: later) == nil)
    }

    // MARK: - When to ask for frames

    @Test func anIdleMapNeedsNoAnimationFrames() {
        let activity = ProjectMapActivity(lastExecuted: [:], isRunning: false)
        #expect(!activity.hasActivity(now: now))
    }

    @Test func aFinishedRunSettlesRatherThanStayingLit() {
        let activity = ProjectMapActivity(
            lastExecuted: ["createUser": now], isRunning: false)
        #expect(activity.hasActivity(now: now))
        let later = now.addingTimeInterval(
            ProjectMapActivity.glowDuration + 1)
        #expect(!activity.hasActivity(now: later))
    }
}
