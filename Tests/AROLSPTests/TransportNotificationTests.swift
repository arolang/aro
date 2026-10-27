// ============================================================
// TransportNotificationTests.swift
// AROLSP - what the document notifications publish (#736)
// ============================================================

#if !os(Windows)
import Testing
import Foundation
@testable import AROLSP

/// The server used to carry two stdio transports with a complete set of
/// handlers each, and `LSPCommand` only ever reached one of them. The
/// unreached half had grown the better `didOpen`, `didClose` and `didSave`
/// behaviour, so deleting it meant porting three publishes onto the half
/// that runs. These pin all three at the JSON-RPC level, which is where the
/// divergence lived: every one of them is about whether a notification
/// results in a `textDocument/publishDiagnostics` going back to the client,
/// and none of them would have failed on a handler read in isolation.
///
/// Serialised because the capture seam is process-wide; nothing else in the
/// suite builds a server, so nothing else publishes into it.
@Suite("LSP document notifications (#736)", .serialized)
struct TransportNotificationTests {

    /// An unknown Compute qualifier — a diagnostic the analyser reports
    /// without needing a workspace around the file.
    private let brokenSource = """
    (Application-Start: Demo) {
        Compute the <total: nosuchqualifier> from <items>.
        Return an <OK: status> for the <startup>.
    }
    """

    private let uri = "file:///tmp/aro-lsp-736/main.aro"

    // MARK: - Helpers

    private func frame(_ message: [String: Any]) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: message)
    }

    /// Every `publishDiagnostics` notification `body` produced, as
    /// (uri, diagnostic count) pairs in the order the client would see them.
    private func published(_ body: () -> Void) -> [(uri: String, count: Int)] {
        AROLanguageServer.DiagnosticsSink.shared.capturing(body).compactMap { data in
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["method"] as? String == "textDocument/publishDiagnostics",
                  let params = json["params"] as? [String: Any],
                  let uri = params["uri"] as? String,
                  let diagnostics = params["diagnostics"] as? [[String: Any]] else { return nil }
            return (uri, diagnostics.count)
        }
    }

    private func didOpen(_ uri: String, _ text: String) -> Data {
        frame([
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": ["textDocument": [
                "uri": uri, "languageId": "aro", "version": 1, "text": text
            ]]
        ])
    }

    // MARK: - Tests

    /// Opening a file compiles it *and* publishes the result. The handler
    /// took the compiled state back from the document manager and dropped
    /// it, and `DocumentManager` deliberately does not fire its `onCompile`
    /// callback for the synchronous `open` path — so a file with an error in
    /// it opened clean and stayed clean until the first keystroke.
    @Test("didOpen publishes the freshly compiled diagnostics")
    func didOpenPublishes() {
        let server = AROLanguageServer()
        let notifications = published {
            _ = server.handleMessage(didOpen(uri, brokenSource))
        }

        #expect(notifications.count == 1)
        #expect(notifications.first?.uri == uri)
        #expect((notifications.first?.count ?? 0) > 0)
    }

    /// Closing a file clears its diagnostics. A client keeps showing
    /// whatever was last published for a URI, so without this the problems
    /// list kept entries for a document the server had already forgotten.
    @Test("didClose clears the document's diagnostics")
    func didCloseClears() {
        let server = AROLanguageServer()
        _ = published { _ = server.handleMessage(didOpen(uri, brokenSource)) }

        let notifications = published {
            _ = server.handleMessage(self.frame([
                "jsonrpc": "2.0",
                "method": "textDocument/didClose",
                "params": ["textDocument": ["uri": self.uri]]
            ]))
        }

        #expect(notifications.count == 1)
        #expect(notifications.first?.uri == uri)
        #expect(notifications.first?.count == 0)
    }

    /// A save republishes *every* open document, not just the saved one.
    /// The saved file may have added or removed an `Application.<Name>`
    /// declaration, and the squiggle that needs clearing is on whichever
    /// open file calls it (#589) — so invalidating the workspace cache
    /// without recompiling, which is all the live path used to do, dropped
    /// the stale answer but never asked again.
    @Test("didSave republishes all open documents")
    func didSaveRepublishesEveryOpenDocument() {
        let server = AROLanguageServer()
        let other = "file:///tmp/aro-lsp-736/other.aro"
        _ = published {
            _ = server.handleMessage(didOpen(uri, brokenSource))
            _ = server.handleMessage(didOpen(other, brokenSource))
        }

        let notifications = published {
            _ = server.handleMessage(self.frame([
                "jsonrpc": "2.0",
                "method": "textDocument/didSave",
                "params": ["textDocument": ["uri": self.uri], "text": self.brokenSource]
            ]))
        }

        #expect(Set(notifications.map(\.uri)) == [uri, other])
        #expect(notifications.allSatisfy { $0.count > 0 })
    }

    /// Editing does *not* publish. `applyChanges` debounces the compile and
    /// hands back the new text with the previous compilation result, so
    /// publishing here would re-emit stale diagnostics on every keystroke
    /// (#352); the debounced compile publishes instead. Stated as a test
    /// because it is the one document notification where silence is correct,
    /// and "didChange doesn't publish" otherwise reads like the bug the
    /// other three cases were.
    @Test("didChange defers to the debounced compile")
    func didChangeDoesNotPublish() {
        let server = AROLanguageServer()
        _ = published { _ = server.handleMessage(didOpen(uri, brokenSource)) }

        let notifications = published {
            _ = server.handleMessage(self.frame([
                "jsonrpc": "2.0",
                "method": "textDocument/didChange",
                "params": [
                    "textDocument": ["uri": self.uri, "version": 2],
                    "contentChanges": [["text": "(Application-Start: Demo) {\n}"]]
                ]
            ]))
        }

        #expect(notifications.isEmpty)
    }

    /// The transport answers requests and stays silent on notifications.
    @Test("requests are answered, notifications are not")
    func requestsAnsweredNotificationsSilent() {
        let server = AROLanguageServer()

        let initialize = server.handleMessage(frame([
            "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:] as [String: Any]
        ]))
        #expect(initialize != nil)

        let unknown = server.handleMessage(frame([
            "jsonrpc": "2.0", "id": 2, "method": "textDocument/nonesuch"
        ]))
        #expect(unknown != nil)
        let decoded = (try? JSONSerialization.jsonObject(with: unknown ?? Data())) as? [String: Any]
        #expect(decoded?["error"] != nil)

        // A cancellation names a request already answered on the read loop's
        // own thread; it is acknowledged rather than reported unknown.
        #expect(server.handleMessage(frame([
            "jsonrpc": "2.0", "method": "$/cancelRequest", "params": ["id": 1]
        ])) == nil)
    }
}
#endif
