// ============================================================
// OrphanedEventCrossFileTests.swift
// AROParser - "no handler exists" across files
// ============================================================
//
// An ARO application has no imports: every feature set is visible to every
// other one, and handlers are routinely kept in their own file. But
// `aro check` compiles a file at a time, so the orphan-event pass only ever
// saw the handlers that happened to live in the file doing the emitting, and
// reported every cross-file handler missing.
//
// On the Crawler that was three warnings — SavePage, ExtractLinks and
// QueueUrl, handled in storage.aro and links.aro — and following the advice
// appended duplicate handlers, so the real ones stopped being the only ones.

import Testing
@testable import AROParser

@Suite("Orphaned events across files")
struct OrphanedEventCrossFileTests {

    private let emitter = """
    (Crawl Page: CrawlPage Handler) {
        Extract the <url> from the <event: url>.
        Emit a <SavePage: event> with <url>.
        Return an <OK: status> for the <crawl>.
    }
    """

    private let handlerInAnotherFile = """
    (Save Page: SavePage Handler) {
        Extract the <url> from the <event: url>.
        Return an <OK: status> for the <saved>.
    }
    """

    private func warnings(_ source: String, externallyHandled: Set<String> = []) -> [Diagnostic] {
        Compiler()
            .compile(source, externallyHandledEvents: externallyHandled)
            .diagnostics
            .filter { $0.severity == .warning && $0.message.contains("no handler exists") }
    }

    @Test("A handler in another file silences the warning")
    func externalHandlerIsRespected() {
        let handled = EventAnalyzer.handledEventTypes(
            in: try! Parser(tokens: try! Lexer.tokenize(handlerInAnotherFile)).parse()
        )

        #expect(handled.contains("SavePage"))
        #expect(warnings(emitter, externallyHandled: handled).isEmpty)
    }

    // The warning has to survive when it is true, or the fix would have
    // silenced a real defect instead of a false one.
    @Test("An event handled nowhere is still reported")
    func genuinelyOrphanedStillWarns() {
        let found = warnings(emitter)

        #expect(found.count == 1)
        #expect(found.first?.message.contains("SavePage") == true)
    }

    @Test("An unrelated handler does not silence it")
    func unrelatedHandlerDoesNotCount() {
        #expect(warnings(emitter, externallyHandled: ["SomethingElse"]).count == 1)
    }

    // Handler and emitter in one file must keep working — that path never
    // needed the external set and must not start depending on it.
    @Test("A handler in the same file still counts")
    func sameFileHandlerStillWorks() {
        #expect(warnings(emitter + "\n\n" + handlerInAnotherFile).isEmpty)
    }

    @Test("handledEventTypes ignores feature sets that are not event handlers")
    func onlyEventHandlersAreCollected() {
        let source = """
        (listUsers: User API) {
            Return an <OK: status> with <users>.
        }
        """
        let program = try! Parser(tokens: try! Lexer.tokenize(source)).parse()

        #expect(EventAnalyzer.handledEventTypes(in: program).isEmpty)
    }
}
