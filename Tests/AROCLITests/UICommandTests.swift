// ============================================================
// UICommandTests.swift
// AROCLI - Tests for `aro ui` launcher discovery
// ============================================================

import Testing
import Foundation
@testable import AROCLI

@Suite("aro ui — launcher discovery")
struct UILauncherTests {

    // MARK: macCandidates

    @Test("macOS: SOLARO_APP comes first when set")
    func macEnvFirst() {
        let candidates = UILauncher.macCandidates(
            env: ["SOLARO_APP": "/tmp/Custom.app"],
            home: "/Users/test"
        )
        #expect(candidates == [
            "/tmp/Custom.app",
            "/Applications/SOLARO.app",
            "/Users/test/Applications/SOLARO.app",
        ])
    }

    @Test("macOS: empty SOLARO_APP is filtered out")
    func macEnvEmptyFiltered() {
        let candidates = UILauncher.macCandidates(
            env: ["SOLARO_APP": ""],
            home: "/Users/test"
        )
        #expect(candidates == [
            "/Applications/SOLARO.app",
            "/Users/test/Applications/SOLARO.app",
        ])
    }

    @Test("macOS: missing SOLARO_APP falls through to system paths")
    func macEnvMissing() {
        let candidates = UILauncher.macCandidates(env: [:], home: "/Users/test")
        #expect(candidates == [
            "/Applications/SOLARO.app",
            "/Users/test/Applications/SOLARO.app",
        ])
    }

    // MARK: linuxCandidates

    @Test("Linux: SOLARO_APPIMAGE comes first when set")
    func linuxEnvFirst() {
        let candidates = UILauncher.linuxCandidates(
            env: ["SOLARO_APPIMAGE": "/tmp/Custom.AppImage"],
            home: "/home/test"
        )
        #expect(candidates == [
            "/tmp/Custom.AppImage",
            "/usr/local/bin/SOLARO.AppImage",
            "/opt/solaro/SOLARO.AppImage",
            "/home/test/.local/bin/SOLARO.AppImage",
        ])
    }

    @Test("Linux: missing SOLARO_APPIMAGE falls through to system paths")
    func linuxEnvMissing() {
        let candidates = UILauncher.linuxCandidates(env: [:], home: "/home/test")
        #expect(candidates == [
            "/usr/local/bin/SOLARO.AppImage",
            "/opt/solaro/SOLARO.AppImage",
            "/home/test/.local/bin/SOLARO.AppImage",
        ])
    }

    // MARK: resolveArgPath

    @Test("resolveArgPath: nil becomes empty (open with no project)")
    func argNil() {
        #expect(UILauncher.resolveArgPath(nil, cwd: "/tmp/cwd") == "")
    }

    @Test("resolveArgPath: '.' expands to cwd")
    func argDot() {
        #expect(UILauncher.resolveArgPath(".", cwd: "/tmp/cwd") == "/tmp/cwd")
    }

    @Test("resolveArgPath: explicit path passes through unchanged")
    func argExplicit() {
        #expect(UILauncher.resolveArgPath("./Examples/HelloWorld", cwd: "/tmp/cwd")
                == "./Examples/HelloWorld")
        #expect(UILauncher.resolveArgPath("/abs/path", cwd: "/tmp/cwd") == "/abs/path")
    }
}
