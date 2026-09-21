// ============================================================
// SigningRescanTests.swift
// SOLARO — the keychain scan is observable while it runs (GitLab #753)
// ============================================================
//
// The bug was not that scanning is slow; it is that `rescan()` set
// `isScanning` to true, ran a blocking `security find-identity` and set it
// back to false inside one main-actor block. SwiftUI never got a turn, so
// the state was unobservable and the control that reads it was dead code —
// while the app was beachballed against the login keychain.

import Testing
import Foundation
@testable import SOLARO

@Suite("Signing rescan")
@MainActor
struct SigningRescanTests {

    @Test func scanningStateIsVisibleWhileTheScanRuns() async throws {
        let settings = SigningSettings()
        #expect(!settings.isScanning)

        settings.rescan()
        // The point of the fix: control returns to the caller — and so to
        // SwiftUI — with the flag still set.
        #expect(settings.isScanning)

        // Let the detached scan finish. `security find-identity` is fast
        // on a normal keychain and returns an empty list where it is
        // missing, which is the CI case.
        for _ in 0..<100 where settings.isScanning {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!settings.isScanning)
    }

    @Test func asecondRescanDoesNotStartASecondScan() async throws {
        let settings = SigningSettings()
        settings.rescan()
        // Opening the tab fires .onAppear, and the button fires it too.
        settings.rescan()
        #expect(settings.isScanning)

        for _ in 0..<100 where settings.isScanning {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!settings.isScanning)
        // And a fresh one is possible afterwards.
        settings.rescan()
        #expect(settings.isScanning)
        for _ in 0..<100 where settings.isScanning {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!settings.isScanning)
    }
}
