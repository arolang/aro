// ============================================================
// AroBinaryVersionTests.swift
// SOLARO — version mismatch detection
// ============================================================

import Testing
@testable import SOLARO

@Suite("AroBinaryVersionCheck")
struct AroBinaryVersionCheckTests {

    @Test func matchingVersionsAreNotMismatched() {
        let check = AroBinaryVersionCheck(
            binaryPath: "/usr/local/bin/aro",
            binaryVersion: "v1.4.3",
            solaroVersion: "v1.4.3"
        )
        #expect(!check.mismatched)
    }

    @Test func differentVersionsAreMismatched() {
        let check = AroBinaryVersionCheck(
            binaryPath: "/usr/local/bin/aro",
            binaryVersion: "v1.4.2",
            solaroVersion: "v1.4.3"
        )
        #expect(check.mismatched)
    }

    @Test func nilBinaryVersionMeansMismatched() {
        let check = AroBinaryVersionCheck(
            binaryPath: "/usr/local/bin/aro",
            binaryVersion: nil,
            solaroVersion: "v1.4.3"
        )
        #expect(check.mismatched)
    }

    @Test func normaliseDropsBuildDateSuffix() {
        // `aro --version` output is typically multiple tokens.
        let normalised = AroBinaryVersionCheck.normalize(
            "aro v1.4.3 (abc123) built on 2026-06-06"
        )
        #expect(normalised == "v1.4.3")
    }

    @Test func normaliseHandlesBareSemver() {
        let normalised = AroBinaryVersionCheck.normalize("1.4.3")
        #expect(normalised == "1.4.3")
    }

    @Test func fingerprintIncludesAllThreeFields() {
        let a = AroBinaryVersionCheck(
            binaryPath: "/a", binaryVersion: "v1", solaroVersion: "v1"
        )
        let b = AroBinaryVersionCheck(
            binaryPath: "/b", binaryVersion: "v1", solaroVersion: "v1"
        )
        let c = AroBinaryVersionCheck(
            binaryPath: "/a", binaryVersion: "v2", solaroVersion: "v1"
        )
        #expect(a.fingerprint != b.fingerprint)
        #expect(a.fingerprint != c.fingerprint)
    }

    @Test func ignoresLeadingTrailingWhitespace() {
        let normalised = AroBinaryVersionCheck.normalize("  v1.4.3  ")
        #expect(normalised == "v1.4.3")
    }
}
