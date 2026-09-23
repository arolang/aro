// ============================================================
// PositionalParameterTests.swift
// ARO Runtime — positional command-line arguments
// ARO-0047 §Positional Arguments, GitLab #857
// ============================================================
//
// `./crawler https://example.com` could not work: the argument parser read
// flags and threw every positional away, so a single-argument tool had to be
// invoked as `./crawler --url https://example.com`.

import Foundation
import Testing
@testable import ARORuntime

@Suite("Positional command-line arguments (#857)")
struct PositionalParameterTests {

    private func storage(_ args: [String], declaring names: [String] = []) -> ParameterStorage {
        let storage = ParameterStorage()
        storage.declarePositionals(names)
        storage.parseArguments(args)
        return storage
    }

    // MARK: - Collection

    @Test("a bare argument is kept as a positional")
    func bareArgumentIsPositional() {
        let storage = storage(["https://example.com", "3"])
        #expect(storage.arguments == ["https://example.com", "3"])
    }

    @Test("positionals are readable as a list without being declared")
    func argumentsListNeedsNoDeclaration() {
        let storage = storage(["a.txt", "b.txt", "c.txt"])
        #expect(storage.get(ParameterStorage.argumentsKey) as? [String]
                == ["a.txt", "b.txt", "c.txt"])
    }

    @Test("flags still parse, and are not positionals")
    func flagsAreNotPositionals() {
        let storage = storage(["--count=5", "-v", "file.txt"])
        #expect(storage.get("count") as? Int == 5)
        #expect(storage.get("v") as? Bool == true)
        #expect(storage.arguments == ["file.txt"])
    }

    // MARK: - Declared names

    @Test("a declared name resolves to the positional at its index")
    func declaredNamesBindByPosition() {
        let storage = storage(["https://example.com", "3"], declaring: ["url", "depth"])
        #expect(storage.get("url") as? String == "https://example.com")
        #expect(storage.get("depth") as? Int == 3)
    }

    @Test("declaration order does not matter")
    func declarationOrderIsIrrelevant() {
        // The interpreter declares names after parsing argv; the compiled
        // binary declares them before. Names and values are stored apart and
        // joined on read precisely so the two cannot diverge.
        let late = ParameterStorage()
        late.parseArguments(["https://example.com"])
        late.declarePositionals(["url"])

        let early = ParameterStorage()
        early.declarePositionals(["url"])
        early.parseArguments(["https://example.com"])

        #expect(late.get("url") as? String == early.get("url") as? String)
        #expect(late.get("url") as? String == "https://example.com")
    }

    @Test("a declared name with no argument is absent")
    func missingPositionalIsAbsent() {
        let storage = storage(["https://example.com"], declaring: ["url", "depth"])
        #expect(storage.get("url") as? String == "https://example.com")
        #expect(storage.get("depth") == nil)
        #expect(storage.has("depth") == false)
    }

    @Test("a flag wins over a positional of the same name")
    func flagBeatsPositional() {
        // `--url` is explicit; a position is inferred. A tool that grows a
        // flag later keeps working for callers who pass it.
        let storage = storage(["--url=https://flag.example", "https://positional.example"],
                              declaring: ["url"])
        #expect(storage.get("url") as? String == "https://flag.example")
    }

    @Test("getAll shows declared names and the argument list")
    func getAllIncludesPositionals() {
        let storage = storage(["https://example.com", "3"], declaring: ["url"])
        let all = storage.getAll()
        #expect(all["url"] as? String == "https://example.com")
        #expect(all[ParameterStorage.argumentsKey] as? [String]
                == ["https://example.com", "3"])
    }

    // MARK: - The `--` terminator

    @Test("everything after -- is positional")
    func doubleDashEndsFlags() {
        let storage = storage(["--verbose", "--", "--not-a-flag", "-x"])
        #expect(storage.get("verbose") as? Bool == true)
        #expect(storage.arguments == ["--not-a-flag", "-x"])
    }

    @Test("`--key value` still consumes its value, which is the documented trap")
    func bareFlagBeforePositionalSwallowsIt() {
        // Nothing in argv says whether `--verbose` takes a value. This
        // behaviour predates positionals and is unchanged by them; `--` and
        // `--key=value` are the two ways to say what was meant. The test is
        // here so that changing it is a deliberate act.
        let swallowed = storage(["--verbose", "https://example.com"])
        #expect(swallowed.get("verbose") as? String == "https://example.com")
        #expect(swallowed.arguments.isEmpty)

        let explicit = storage(["--verbose=true", "https://example.com"])
        #expect(explicit.get("verbose") as? Bool == true)
        #expect(explicit.arguments == ["https://example.com"])
    }

    @Test("clear forgets positionals and their declaration")
    func clearResetsEverything() {
        let storage = storage(["https://example.com"], declaring: ["url"])
        storage.clear()
        #expect(storage.arguments.isEmpty)
        #expect(storage.declaredPositionals.isEmpty)
        #expect(storage.get("url") == nil)
    }
}
