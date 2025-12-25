// ============================================================
// EventChainAnalyzerTests.swift
// ARO Parser - Circular Event Chain Detection Tests
// ============================================================

import Testing
@testable import AROParser

// MARK: - Event Cycle Tests

@Suite("Event Cycle Tests")
struct EventCycleTests {

    @Test("Event cycle creation")
    func testEventCycleCreation() {
        let cycle = EventCycle(
            events: ["UserCreated", "FileCreated", "UserCreated"],
            featureSets: ["Write User File", "Handle File Created"],
            location: nil
        )

        #expect(cycle.events.count == 3)
        #expect(cycle.featureSets.count == 2)
        #expect(cycle.description == "UserCreated → FileCreated → UserCreated")
    }

    @Test("Event cycle equality")
    func testEventCycleEquality() {
        let cycle1 = EventCycle(
            events: ["A", "B", "A"],
            featureSets: ["Handler1", "Handler2"],
            location: nil
        )
        let cycle2 = EventCycle(
            events: ["A", "B", "A"],
            featureSets: ["Handler1", "Handler2"],
            location: nil
        )

        #expect(cycle1 == cycle2)
    }
}

// MARK: - Event Chain Analyzer Tests

@Suite("Event Chain Analyzer Tests")
struct EventChainAnalyzerTests {

    @Test("No cycles in simple program")
    func testNoCyclesSimple() throws {
        let source = """
        (Create User: User API) {
            <Extract> the <data> from the <request>.
            <Create> the <user> with <data>.
            <Emit> a <UserCreated: event> with <user>.
            <Return> an <OK: status> for the <user>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        // No cycles detected
        #expect(!diagnostics.hasErrors)
    }

    @Test("No cycles when handler doesn't emit")
    func testNoCyclesNoEmit() throws {
        let source = """
        (Create User: User API) {
            <Emit> a <UserCreated: event> with <user>.
            <Return> an <OK: status> for the <user>.
        }

        (Log User: UserCreated Handler) {
            <Extract> the <user> from the <event>.
            <Log> the <message> for the <console> with "User created".
            <Return> an <OK: status> for the <log>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        // No cycles - handler doesn't emit any events
        #expect(!diagnostics.hasErrors)
    }

    @Test("No cycles with linear chain")
    func testNoCyclesLinearChain() throws {
        let source = """
        (Create User: User API) {
            <Emit> a <UserCreated: event> with <user>.
            <Return> an <OK: status> for the <user>.
        }

        (Handle User Created: UserCreated Handler) {
            <Emit> a <EmailSent: event> with <notification>.
            <Return> an <OK: status> for the <handler>.
        }

        (Handle Email Sent: EmailSent Handler) {
            <Log> the <message> for the <console>.
            <Return> an <OK: status> for the <handler>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        // No cycle - linear chain A -> B -> C (C doesn't emit back to A)
        #expect(!diagnostics.hasErrors)
    }

    @Test("Detects simple cycle A -> B -> A")
    func testSimpleCycleABA() throws {
        let source = """
        (Handle Alpha: EventAlpha Handler) {
            <Emit> the <EventBeta: event> for the <trigger>.
            <Return> an <OK: status> for the <handler>.
        }

        (Handle Beta: EventBeta Handler) {
            <Emit> the <EventAlpha: event> for the <trigger>.
            <Return> an <OK: status> for the <handler>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        // Cycle detected: EventAlpha -> EventBeta -> EventAlpha
        let cycleErrors = diagnostics.errors.filter { $0.message.contains("Circular event chain") }
        #expect(cycleErrors.count >= 1)
    }

    @Test("Detects longer cycle A -> B -> C -> A")
    func testLongerCycleABCA() throws {
        let source = """
        (Handle Alpha: EventAlpha Handler) {
            <Emit> the <EventBeta: event> for the <trigger>.
            <Return> an <OK: status> for the <handler>.
        }

        (Handle Beta: EventBeta Handler) {
            <Emit> the <EventGamma: event> for the <trigger>.
            <Return> an <OK: status> for the <handler>.
        }

        (Handle Gamma: EventGamma Handler) {
            <Emit> the <EventAlpha: event> for the <trigger>.
            <Return> an <OK: status> for the <handler>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        // Cycle detected: EventAlpha -> EventBeta -> EventGamma -> EventAlpha
        let cycleErrors = diagnostics.errors.filter { $0.message.contains("Circular event chain") }
        #expect(cycleErrors.count >= 1)
    }

    @Test("Detects self-loop")
    func testSelfLoop() throws {
        let source = """
        (Handle Event: SomeEvent Handler) {
            <Emit> the <SomeEvent: event> for the <trigger>.
            <Return> an <OK: status> for the <handler>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        // Self-loop detected: SomeEvent -> SomeEvent
        let cycleErrors = diagnostics.errors.filter { $0.message.contains("Circular event chain") }
        #expect(cycleErrors.count >= 1)
    }

    @Test("Detects emit inside Match statement")
    func testEmitInsideMatch() throws {
        let source = """
        (Handle Alpha: EventAlpha Handler) {
            <Extract> the <status> from the <event: status>.
            <Match> the <status>:
                case <success>:
                    <Emit> the <EventBeta: event> for the <trigger>.
                otherwise:
                    <Log> the <message> for the <console>.
            <Return> an <OK: status> for the <handler>.
        }

        (Handle Beta: EventBeta Handler) {
            <Emit> the <EventAlpha: event> for the <trigger>.
            <Return> an <OK: status> for the <handler>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        // Cycle detected even though Emit is inside Match
        let cycleErrors = diagnostics.errors.filter { $0.message.contains("Circular event chain") }
        #expect(cycleErrors.count >= 1)
    }

    @Test("Detects emit inside ForEach loop")
    func testEmitInsideForEach() throws {
        let source = """
        (Handle Alpha: EventAlpha Handler) {
            <Extract> the <items> from the <event: items>.
            <For-each> <item> in <items>:
                <Emit> the <EventBeta: event> for the <trigger>.
            <Return> an <OK: status> for the <handler>.
        }

        (Handle Beta: EventBeta Handler) {
            <Emit> the <EventAlpha: event> for the <trigger>.
            <Return> an <OK: status> for the <handler>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        // Cycle detected even though Emit is inside ForEach
        let cycleErrors = diagnostics.errors.filter { $0.message.contains("Circular event chain") }
        #expect(cycleErrors.count >= 1)
    }

    @Test("Excludes Socket Event Handler from cycle detection")
    func testExcludesSocketHandler() throws {
        let source = """
        (Handle Socket: Socket Event Handler) {
            <Emit> the <EventAlpha: event> for the <trigger>.
            <Return> an <OK: status> for the <handler>.
        }

        (Handle Alpha: EventAlpha Handler) {
            <Log> the <message> for the <console>.
            <Return> an <OK: status> for the <handler>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        // Socket Event Handler is excluded from cycle detection, so no cycle
        let cycleErrors = diagnostics.errors.filter { $0.message.contains("Circular event chain") }
        #expect(cycleErrors.isEmpty)
    }

    @Test("Excludes File Event Handler from cycle detection")
    func testExcludesFileHandler() throws {
        let source = """
        (Handle File: File Event Handler) {
            <Emit> the <EventAlpha: event> for the <trigger>.
            <Return> an <OK: status> for the <handler>.
        }

        (Handle Alpha: EventAlpha Handler) {
            <Log> the <message> for the <console>.
            <Return> an <OK: status> for the <handler>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        // File Event Handler is excluded from cycle detection, so no cycle
        let cycleErrors = diagnostics.errors.filter { $0.message.contains("Circular event chain") }
        #expect(cycleErrors.isEmpty)
    }

    @Test("Multiple handlers for same event type")
    func testMultipleHandlersSameEvent() throws {
        let source = """
        (Handler One: EventAlpha Handler) {
            <Log> the <message> for the <console>.
            <Return> an <OK: status> for the <handler>.
        }

        (Handler Two: EventAlpha Handler) {
            <Emit> the <EventBeta: event> for the <trigger>.
            <Return> an <OK: status> for the <handler>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        // No cycle - multiple handlers for same event, but no circular chain
        let cycleErrors = diagnostics.errors.filter { $0.message.contains("Circular event chain") }
        #expect(cycleErrors.isEmpty)
    }

    @Test("Handler emits multiple events with one causing cycle")
    func testHandlerEmitsMultipleEvents() throws {
        let source = """
        (Handle Alpha: EventAlpha Handler) {
            <Emit> the <EventBeta: event> for the <trigger>.
            <Emit> the <EventGamma: event> for the <trigger>.
            <Return> an <OK: status> for the <handler>.
        }

        (Handle Beta: EventBeta Handler) {
            <Emit> the <EventAlpha: event> for the <trigger>.
            <Return> an <OK: status> for the <handler>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        // Cycle through EventBeta path: EventAlpha -> EventBeta -> EventAlpha
        let cycleErrors = diagnostics.errors.filter { $0.message.contains("Circular event chain") }
        #expect(cycleErrors.count >= 1)
    }

    @Test("Error message includes event chain")
    func testErrorMessageContent() throws {
        let source = """
        (Handle Alpha: Alpha Handler) {
            <Emit> the <Beta: event> for the <trigger>.
            <Return> an <OK: status> for the <handler>.
        }

        (Handle Beta: Beta Handler) {
            <Emit> the <Alpha: event> for the <trigger>.
            <Return> an <OK: status> for the <handler>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        let cycleErrors = diagnostics.errors.filter { $0.message.contains("Circular event chain") }
        #expect(cycleErrors.count >= 1)

        let errorMessage = cycleErrors[0].message
        // Should show the cycle chain with arrows
        #expect(errorMessage.contains("→"))
        #expect(errorMessage.contains("Alpha") || errorMessage.contains("Beta"))
    }

    @Test("Error includes helpful hints")
    func testErrorIncludesHints() throws {
        let source = """
        (Handle Alpha: EventAlpha Handler) {
            <Emit> the <EventAlpha: event> for the <trigger>.
            <Return> an <OK: status> for the <handler>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        let cycleErrors = diagnostics.errors.filter { $0.message.contains("Circular event chain") }
        #expect(cycleErrors.count >= 1)

        let error = cycleErrors[0]
        #expect(error.hints.count >= 1)
        #expect(error.hints.contains { $0.contains("infinite loop") || $0.contains("breaking") })
    }
}

// MARK: - Integration Tests

@Suite("Event Chain Integration Tests")
struct EventChainIntegrationTests {

    @Test("Cycle detection works with full compilation")
    func testCycleDetectionWithCompiler() throws {
        let source = """
        (Handle Alpha: EventAlpha Handler) {
            <Emit> the <EventBeta: event> for the <trigger>.
            <Return> an <OK: status> for the <handler>.
        }

        (Handle Beta: EventBeta Handler) {
            <Emit> the <EventAlpha: event> for the <trigger>.
            <Return> an <OK: status> for the <handler>.
        }
        """
        let compiler = Compiler()
        let result = compiler.compile(source)

        #expect(!result.isSuccess)
        #expect(result.hasErrors)

        let cycleError = result.diagnostics.first { $0.message.contains("Circular event chain") }
        #expect(cycleError != nil)
    }
}
