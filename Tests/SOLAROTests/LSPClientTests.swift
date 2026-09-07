// ============================================================
// LSPClientTests.swift
// SOLARO — crash-restart policy + document buffering (GitLab #530)
// ============================================================
//
// Headless coverage for the two testable cores of the LSP client's
// crash handling: the pure restart/backoff decision logic, and the
// bounded document mirror that replaced the unbounded
// one-closure-per-keystroke op queue.

import Testing
import Foundation
@testable import SOLARO

@Suite("LSPRestartPolicy")
struct LSPRestartPolicyTests {

    private let policy = LSPRestartPolicy()  // 3 attempts, 0.5s base, 30s healthy

    @Test("Backoff doubles per consecutive crash")
    func backoffDoubles() {
        #expect(policy.decision(attemptsSoFar: 0, uptime: 1)
                == .restart(afterDelay: 0.5, attempt: 1))
        #expect(policy.decision(attemptsSoFar: 1, uptime: 1)
                == .restart(afterDelay: 1.0, attempt: 2))
        #expect(policy.decision(attemptsSoFar: 2, uptime: 1)
                == .restart(afterDelay: 2.0, attempt: 3))
    }

    @Test("Gives up after the attempt cap — no infinite crash loop")
    func givesUpAtCap() {
        #expect(policy.decision(attemptsSoFar: 3, uptime: 1) == .giveUp)
        #expect(policy.decision(attemptsSoFar: 30, uptime: 1) == .giveUp)
    }

    @Test("A healthy uptime resets the attempt series")
    func healthyUptimeResets() {
        // Even after the cap was reached, a server that ran for a
        // long while before dying gets a fresh series.
        #expect(policy.decision(attemptsSoFar: 3, uptime: 60)
                == .restart(afterDelay: 0.5, attempt: 1))
        // Just under the healthy threshold still counts as a crash
        // loop.
        #expect(policy.decision(attemptsSoFar: 3, uptime: 29) == .giveUp)
    }
}

@Suite("AROLSPClient document buffering")
struct LSPClientDocumentTests {

    @Test("Doc ops before the handshake stay bounded by open documents, not keystrokes")
    @MainActor
    func opsAreBoundedPerDocument() {
        // No start() — the client is permanently not-ready, the
        // same situation as a crashed server. Before GitLab #530
        // every one of these calls appended a closure capturing the
        // full document text.
        let client = AROLSPClient()
        let url = URL(fileURLWithPath: "/tmp/lsp-test/main.aro")
        client.didOpen(url: url, text: "v0")
        for i in 1...1000 {
            client.didChange(url: url, text: "version \(i)")
        }
        #expect(client.openDocuments.count == 1)
        // The mirror holds the LATEST text — that is what a
        // restarted server must be replayed.
        #expect(client.openDocuments[url] == "version 1000")
    }

    @Test("didClose drops the mirror and stale diagnostics even while the server is down")
    @MainActor
    func didCloseDropsMirrorWhileDown() {
        let client = AROLSPClient()
        let url = URL(fileURLWithPath: "/tmp/lsp-test/users.aro")
        client.didOpen(url: url, text: "text")
        client.diagnostics[url] = [
            .init(line: 1, character: 1, endLine: 1, endCharacter: 2,
                  severity: .error, message: "stale")
        ]
        client.didClose(url: url)
        // Closed documents must not come back from a crash-restart
        // replay, and their diagnostics must not linger.
        #expect(client.openDocuments[url] == nil)
        #expect(client.diagnostics[url] == nil)
    }

    @Test("Multiple documents each keep one slot")
    @MainActor
    func oneSlotPerDocument() {
        let client = AROLSPClient()
        let a = URL(fileURLWithPath: "/tmp/lsp-test/a.aro")
        let b = URL(fileURLWithPath: "/tmp/lsp-test/b.aro")
        for i in 0..<50 {
            client.didChange(url: a, text: "a\(i)")
            client.didChange(url: b, text: "b\(i)")
        }
        #expect(client.openDocuments.count == 2)
        #expect(client.openDocuments[a] == "a49")
        #expect(client.openDocuments[b] == "b49")
    }
}
