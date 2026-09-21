// ============================================================
// NewPluginTests.swift
// SOLARO — scaffolding a plugin (GitLab #768)
// ============================================================
//
// The Plugins sidebar could browse, install, reveal and uninstall. The
// one verb missing was "new", although the CLI has had aro new plugin
// all along and ARO-0087 is a whole proposal about plugin developer
// experience.

import Testing
import Foundation
@testable import SOLARO

@Suite("New plugin")
struct NewPluginTests {

    // MARK: - Languages

    @Test func everyLanguageTheCLIScaffoldsIsOffered() {
        // `aro new plugin --lang` takes exactly these, and the flag is
        // required — there is no default to fall back on.
        let offered = Set(PluginLanguage.allCases.map(\.rawValue))
        #expect(offered == ["swift", "rust", "c", "cpp", "python", "aro"])
    }

    @Test func eachLanguageExplainsItself() {
        for language in PluginLanguage.allCases {
            #expect(!language.displayName.isEmpty)
            #expect(!language.detail.isEmpty)
        }
    }

    // MARK: - Name validation

    @Test func agoodNameIsAccepted() {
        #expect(PluginNameCheck.rejection(for: "markdown-render",
                                          existing: []) == nil)
        #expect(PluginNameCheck.rejection(for: "sqlite_2",
                                          existing: []) == nil)
    }

    @Test func anEmptyNameIsRejected() {
        #expect(PluginNameCheck.rejection(for: "   ", existing: []) != nil)
    }

    @Test func aNameAlreadyInUseIsCaughtBeforeTheCLIRuns() {
        // Better than an exit status: the user is told which name and
        // can change it without reading a log.
        let rejection = PluginNameCheck.rejection(for: "hash",
                                                  existing: ["hash"])
        #expect(rejection?.contains("Plugins/hash") == true)
    }

    @Test func surroundingSpaceDoesNotMakeANameNew() {
        #expect(PluginNameCheck.rejection(for: "  hash  ",
                                          existing: ["hash"]) != nil)
    }

    @Test func pathSeparatorsAndDotsAreRejected() {
        // The name becomes a directory under Plugins/ and a handle in
        // plugin.yaml, so it has to survive both.
        #expect(PluginNameCheck.rejection(for: "../escape", existing: []) != nil)
        #expect(PluginNameCheck.rejection(for: "a/b", existing: []) != nil)
        #expect(PluginNameCheck.rejection(for: ".hidden", existing: []) != nil)
        #expect(PluginNameCheck.rejection(for: "with space", existing: []) != nil)
    }

    // MARK: - Process

    @MainActor
    @Test func aRejectedNameFailsWithoutSpawningAnything() {
        let process = NewPluginProcess()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        process.create(name: "", language: .swift,
                       project: Project(rootPath: root), existing: [])
        guard case .failed(let message) = process.state else {
            Issue.record("expected a failure, got \(process.state)")
            return
        }
        #expect(!message.isEmpty)
        #expect(process.log.isEmpty)
    }

    @MainActor
    @Test func resettingClearsTheLogAndTheState() {
        let process = NewPluginProcess()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        process.create(name: "a/b", language: .swift,
                       project: Project(rootPath: root), existing: [])
        process.reset()
        #expect(process.state == .idle)
        #expect(process.log.isEmpty)
    }
}
