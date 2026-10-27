// ============================================================
// InteractiveInputProtocolTests.swift
// AROCLI — asking a notebook front-end a question
// ARO-0091 §Interactive input, GitLab #690
// ============================================================
//
// The socket and pipe loops are driven end-to-end by hand (see the MR);
// what belongs here is the part that must be exactly right and is
// testable without a front-end: the protocol's new fields, the stdin
// reader that makes a *bounded* wait possible, and the session seam the
// two servers register their channel on.

import Testing
import Foundation
@testable import AROCLI
import ARORuntime

// MARK: - Protocol shape

@Suite("JSON protocol: input_request / input_reply (GitLab #690)")
struct JSONREPLInputProtocolTests {

    private func decode(_ json: String) throws -> JSONREPLRequest {
        try JSONDecoder().decode(JSONREPLRequest.self, from: Data(json.utf8))
    }

    @Test("An execute request opts into questions with allowStdin")
    func allowStdinDecodes() throws {
        let request = try decode(#"{"id":1,"type":"execute","code":"x","allowStdin":true}"#)
        #expect(request.allowStdin == true)
    }

    @Test("Absent allowStdin is absent — the server reads it as false")
    func allowStdinDefaultsOff() throws {
        // A client that has never heard of `input_request` must not be
        // sent one: it would never reply, and the cell would wait out
        // the whole timeout before failing.
        let request = try decode(#"{"id":1,"type":"execute","code":"x"}"#)
        #expect(request.allowStdin == nil)
    }

    @Test("An input_reply carries the answer under the asking request's id")
    func inputReplyDecodes() throws {
        let reply = try decode(#"{"id":7,"type":"input_reply","value":"Ada"}"#)
        #expect(reply.id == 7)
        #expect(reply.type == "input_reply")
        #expect(reply.value == "Ada")
        #expect(reply.status == nil)
    }

    @Test("A client that will not answer says so with status error")
    func inputReplyRefusal() throws {
        let reply = try decode(#"{"id":7,"type":"input_reply","status":"error"}"#)
        #expect(reply.status == "error")
        #expect(reply.value == nil)
    }

    @Test("input_request is shaped like Jupyter's")
    func inputRequestEncoding() throws {
        // `prompt` + `password`, answered by `value`: a kernel sitting
        // between the two protocols is a relay, not a translator.
        let line = JSONREPLEncoder.inputRequest(id: 3, prompt: "Password: ", password: true)
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]

        #expect(object?["type"] as? String == "input_request")
        #expect(object?["id"] as? Int == 3)
        #expect(object?["prompt"] as? String == "Password: ")
        #expect(object?["password"] as? Bool == true)
    }
}

// MARK: - The stdin reader

@Suite("StdinLineReader (GitLab #690)")
struct StdinLineReaderTests {

    @Test("An unanswered wait ends — it does not hang")
    func timesOut() {
        // The whole reason this type exists: abandoning a blocking
        // `readLine` on timeout leaves a thread that eats the next line.
        // A queue poll leaves the line where it is.
        let reader = StdinLineReader()
        #expect(reader.next(timeoutSeconds: 0.05) == .timedOut)
    }

    @Test("A pushed-back line comes out first, and stays available")
    func unreadIsFIFOAtTheHead() {
        // `shutdown` arriving while a question is open: the statement
        // fails on it, and the request loop still has to see it.
        let reader = StdinLineReader()
        reader.unread(#"{"id":2,"type":"shutdown"}"#)
        reader.unread(#"{"id":1,"type":"input_reply","value":"first"}"#)

        #expect(reader.next(timeoutSeconds: 0.05)
            == .line(#"{"id":1,"type":"input_reply","value":"first"}"#))
        #expect(reader.next(timeoutSeconds: 0.05) == .line(#"{"id":2,"type":"shutdown"}"#))
        #expect(reader.next(timeoutSeconds: 0.05) == .timedOut)
    }
}

// MARK: - The session seam

/// A front-end that answers from a script, like the two real servers do
/// over their own transports.
private final class ScriptedChannel: InteractiveInputService, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String]
    private var asked: [String] = []

    init(_ answers: [String]) { self.answers = answers }

    var questions: [String] { lock.withLock { asked } }

    func requestLine(prompt: String, hidden: Bool) async throws -> String {
        lock.withLock {
            asked.append(prompt)
            return answers.isEmpty ? "" : answers.removeFirst()
        }
    }
}

@Suite("A session's interactive input channel (GitLab #690)", .serialized)
struct REPLSessionInteractiveInputTests {

    @Test("A cell's Prompt is answered by the registered channel")
    func cellPromptIsAnswered() async {
        let session = REPLSession()
        let channel = ScriptedChannel(["Ada Lovelace"])
        session.useInteractiveInput(channel)

        let engine = REPLCellEngine(session: session)
        let outcome = await engine.executeCell(#"Prompt the <name> with "Your name: "."#)

        #expect(outcome.error == nil, "\(outcome.error?.value ?? "")")
        #expect(channel.questions == ["Your name: "])
        #expect(session.getVariable("name") as? String == "Ada Lovelace")
    }

    @Test("`:clear` does not lose the channel")
    func channelSurvivesClear() async {
        // `clear()` builds a fresh RuntimeContext, and a session that
        // forgot its channel would start failing statements that worked
        // a moment earlier.
        let session = REPLSession()
        let channel = ScriptedChannel(["first", "second"])
        session.useInteractiveInput(channel)

        let engine = REPLCellEngine(session: session)
        _ = await engine.executeCell(#"Prompt the <name> with "Once: "."#)
        session.clear()
        let outcome = await engine.executeCell(#"Prompt the <name> with "Again: "."#)

        #expect(outcome.error == nil, "\(outcome.error?.value ?? "")")
        #expect(channel.questions == ["Once: ", "Again: "])
        #expect(session.getVariable("name") as? String == "second")
    }

    @Test("A KeyPress handler is still undelivered, for the sharper reason")
    func keyPressStaysUndelivered() {
        // GitLab #688 classified it undelivered *because of* #690. The
        // classification stands: this channel answers a question the
        // program asked, and a KeyPress handler wants unsolicited
        // keystrokes from a raw keyboard. The reason now says which half
        // works.
        guard case .undelivered(let reason) =
                REPLSession.handlerFamily(for: "KeyPress Handler") else {
            Issue.record("KeyPress should still be undelivered in a session")
            return
        }
        #expect(reason.contains("raw keyboard"))
        #expect(reason.contains("Prompt"))
    }
}
