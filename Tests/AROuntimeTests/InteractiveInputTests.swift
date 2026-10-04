// ============================================================
// InteractiveInputTests.swift
// ARO Runtime — Prompt / Select / Ask need an answerer, not a TTY
// ARO-0083 §5.2–5.3, GitLab #690
// ============================================================
//
// Two things are under test, and the second is the one that made the
// first invisible:
//
//   * `Prompt` and `Select` ask whoever is registered — a terminal under
//     `aro run`, a notebook front-end behind a pipe — and fail with a
//     reason when nobody can answer, rather than with the name of a
//     Swift type.
//   * `Prompt the <name> with "Your name: ".` puts its message in
//     expression position, which the executor's fast path used to bind
//     straight to `<name>`. The action never ran: no question was asked,
//     nobody answered, and the statement succeeded with the prompt text
//     as the user's name.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - Doubles

/// A front-end that answers from a script.
private final class ScriptedInput: InteractiveInputService, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String]
    private var asked: [(prompt: String, hidden: Bool)] = []

    init(_ answers: [String]) {
        self.answers = answers
    }

    var questions: [(prompt: String, hidden: Bool)] {
        lock.withLock { asked }
    }

    func requestLine(prompt: String, hidden: Bool) async throws -> String {
        lock.withLock {
            asked.append((prompt, hidden))
            return answers.isEmpty ? "" : answers.removeFirst()
        }
    }
}

/// A front-end that is there but will not answer — `allow_stdin: false`,
/// a dismissed prompt.
private struct RefusingInput: InteractiveInputService {
    func requestLine(prompt: String, hidden: Bool) async throws -> String {
        throw InteractiveInputError.declined(
            action: "Prompt", detail: "the test front-end refuses")
    }
}

// MARK: - Helpers

private func context(_ services: [any InteractiveInputService] = []) -> RuntimeContext {
    let context = RuntimeContext(featureSetName: "Ask", businessActivity: "Interactive")
    for service in services {
        context.register(service as any InteractiveInputService)
    }
    return context
}

private func prompt(
    message: String,
    specifiers: [String] = [],
    in context: RuntimeContext
) async throws -> any Sendable {
    context.bind("_with_", value: message)
    return try await PromptAction().execute(
        result: ResultDescriptor(base: "answer", specifiers: specifiers,
                                 span: SourceSpan(at: SourceLocation())),
        object: ObjectDescriptor(preposition: .with, base: "_expression_", specifiers: [],
                                 span: SourceSpan(at: SourceLocation())),
        context: context)
}

private func select(
    options: [String],
    message: String,
    specifiers: [String] = [],
    in context: RuntimeContext
) async throws -> any Sendable {
    context.bind("_with_", value: message)
    context.bind("options", value: options)
    return try await SelectAction().execute(
        result: ResultDescriptor(base: "choice", specifiers: specifiers,
                                 span: SourceSpan(at: SourceLocation())),
        object: ObjectDescriptor(preposition: .from, base: "options", specifiers: [],
                                 span: SourceSpan(at: SourceLocation())),
        context: context)
}

// MARK: - Resolution

@Suite("Who answers an interactive question (GitLab #690)")
struct InteractiveInputResolutionTests {

    @Test("With nothing registered there is no answerer")
    func noAnswerer() {
        #expect(InteractiveInput.provider(in: context()) == nil)
    }

    @Test("A front-end channel wins over the terminal service")
    func frontEndWinsOverTerminal() {
        // Both exist whenever `aro repl --json` is started from a
        // terminal. The client driving the session is the one whose user
        // is looking at the question.
        let scripted = ScriptedInput(["from the front-end"])
        let runtime = context([scripted])
        runtime.register(TerminalService())

        #expect(InteractiveInput.provider(in: runtime) is ScriptedInput)
    }

    @Test("The terminal service answers when it is all there is")
    func terminalAnswers() {
        let runtime = context()
        runtime.register(TerminalService())
        #expect(InteractiveInput.provider(in: runtime) is TerminalService)
    }

    @Test("The timeout is finite by default — a cell must not hang")
    func timeoutIsFinite() {
        // The default is the way out of a wait nobody will end. Only an
        // explicit ARO_INPUT_TIMEOUT_SECONDS=0 opts into waiting forever.
        if ProcessInfo.processInfo.environment["ARO_INPUT_TIMEOUT_SECONDS"] == nil {
            #expect(InteractiveInput.timeoutSeconds == 300)
        }
        #expect(InteractiveInput.timeoutSeconds >= 0)
    }
}

// MARK: - Prompt

@Suite("Prompt (GitLab #690)")
struct PromptAnswerTests {

    @Test("Nobody to ask fails the statement, naming the reason")
    func unavailableNamesTheReason() async throws {
        await #expect(throws: ActionError.self) {
            _ = try await prompt(message: "Your name: ", in: context())
        }

        do {
            _ = try await prompt(message: "Your name: ", in: context())
            Issue.record("expected the statement to fail")
        } catch let error as ActionError {
            guard case .interactiveInputUnavailable(let reason) = error else {
                Issue.record("expected interactiveInputUnavailable, got \(error)")
                return
            }
            // The old failure was `Service not registered:
            // 'TerminalService'`. What a user needs is which front-end
            // could have answered and how to get one.
            #expect(reason.contains("no terminal"))
            #expect(reason.contains("input channel"))
            #expect(reason.contains("Prompt"))
            #expect(!reason.contains("TerminalService"))
        }
    }

    @Test("The reason survives into the statement's error text")
    func reasonIsCurated() {
        // ARO-0006 renders the statement as the message, which for this
        // failure says nothing: `Cannot prompt the name with the
        // _expression_.` is a faithful rendering of a statement that is
        // perfectly fine. The hint is the whole content of the failure.
        let hint = AROError.curatedHint(
            for: ActionError.interactiveInputUnavailable(reason: "no answerer here"))
        #expect(hint == "no answerer here")
    }

    @Test("A registered front-end answers, and the answer is bound")
    func frontEndAnswers() async throws {
        let scripted = ScriptedInput(["Ada Lovelace"])
        let runtime = context([scripted])

        let result = try await prompt(message: "Your name: ", in: runtime)

        #expect(runtime.resolveAny("answer") as? String == "Ada Lovelace")
        #expect((result as? PromptResult)?.value == "Ada Lovelace")
        #expect(scripted.questions.map(\.prompt) == ["Your name: "])
    }

    @Test("`hidden` reaches the front-end so it can mask the field")
    func hiddenIsForwarded() async throws {
        let scripted = ScriptedInput(["s3cret"])
        let runtime = context([scripted])

        _ = try await prompt(message: "Password: ", specifiers: ["hidden"], in: runtime)

        #expect(scripted.questions.first?.hidden == true)
    }

    @Test("A front-end that refuses fails the statement with its own reason")
    func refusalIsReported() async throws {
        do {
            _ = try await prompt(message: "Your name: ", in: context([RefusingInput()]))
            Issue.record("expected the refusal to fail the statement")
        } catch let error as ActionError {
            guard case .interactiveInputUnavailable(let reason) = error else {
                Issue.record("expected interactiveInputUnavailable, got \(error)")
                return
            }
            #expect(reason.contains("the test front-end refuses"))
        }
    }
}

// MARK: - Select

@Suite("Select (GitLab #690)")
struct SelectAnswerTests {

    @Test("A front-end with no picker gets the numbered menu")
    func numberedMenu() async throws {
        let scripted = ScriptedInput(["2"])
        let runtime = context([scripted])

        let result = try await select(
            options: ["Red", "Green", "Blue"], message: "Pick a colour:", in: runtime)

        #expect(runtime.resolveAny("choice") as? String == "Green")
        #expect((result as? SelectResult)?.selected == ["Green"])
        // The menu itself goes to stdout (captured as cell output); what
        // the front-end is asked for is the number.
        #expect(scripted.questions.first?.prompt.contains("number") == true)
    }

    @Test("Multi-select takes several numbers")
    func multiSelect() async throws {
        let runtime = context([ScriptedInput(["1, 3"])])

        let result = try await select(
            options: ["Red", "Green", "Blue"], message: "Pick:",
            specifiers: ["multi-select"], in: runtime)

        #expect((result as? SelectResult)?.selected == ["Red", "Blue"])
        #expect(runtime.resolveAny("choice") as? [String] == ["Red", "Blue"])
    }

    @Test("An out-of-range answer selects nothing")
    func outOfRange() async throws {
        // Same answer the terminal menu has always given for a number
        // that is not on it.
        let result = try await select(
            options: ["Red", "Green"], message: "Pick:",
            in: context([ScriptedInput(["9"])]))

        #expect((result as? SelectResult)?.selected.isEmpty == true)
    }

    @Test("Nobody to ask fails the statement, naming Select")
    func unavailable() async throws {
        do {
            _ = try await select(options: ["Red"], message: "Pick:", in: context())
            Issue.record("expected the statement to fail")
        } catch let error as ActionError {
            guard case .interactiveInputUnavailable(let reason) = error else {
                Issue.record("expected interactiveInputUnavailable, got \(error)")
                return
            }
            #expect(reason.contains("Select"))
        }
    }
}

// MARK: - The statement actually runs

@Suite("An interactive statement is not swallowed by the fast path (GitLab #690)")
struct InteractiveFastPathTests {

    @Test("Prompt, Ask, Select and Choose always execute")
    func verbsAlwaysExecute() {
        // The message sits in expression position, so without this the
        // executor binds the message to the result and skips the action.
        // They cannot go in `mustRunForEffect` instead: that list is for
        // verbs which bind no result.
        for verb in ["prompt", "ask", "select", "choose"] {
            #expect(VerbSets.requestVerbs.contains(verb), "\(verb) must always execute")
            #expect(!ActionRoleCatalog.mustRunForEffect(verb))
        }
    }

    @Test("A Prompt statement in a program reaches the front-end")
    func promptRunsInAProgram() async throws {
        let source = """
        (Application-Start: Interactive Demo) {
            Prompt the <name> with "Your name: ".
            Return an <OK: status> for the <startup>.
        }
        """
        let compiled = Compiler.compile(source)
        #expect(compiled.isSuccess, "test program failed to compile: \(compiled.diagnostics)")

        let scripted = ScriptedInput(["Ada Lovelace"])
        let engine = ExecutionEngine()
        await engine.register(service: scripted as any InteractiveInputService)
        _ = try await engine.execute(compiled.analyzedProgram)

        // Before the fix this was empty: `<name>` was bound to
        // "Your name: " and the action never ran.
        #expect(scripted.questions.map(\.prompt) == ["Your name: "])
    }
}
