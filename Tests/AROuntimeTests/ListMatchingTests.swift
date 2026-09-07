// ============================================================
// ListMatchingTests.swift
// ARO Runtime — `List … matching "<glob>"` (ARO-0036 §6, GitLab #518)
// ============================================================
//
// The hazard the issue names: without a glob on List, people narrowed a
// listing with `Filter … contains ".csv"`, which is substring matching and
// therefore keeps `report.csvx`. These tests pin the glob semantics that
// replace it — fnmatch(3), case-sensitive, against the entry name.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - Glob semantics

@Suite("Glob matching (ARO-0036 §6.2)")
struct GlobMatcherTests {

    /// (name, pattern, expected). The corpus both implementations must agree on.
    static let corpus: [(String, String, Bool)] = [
        // The issue's hazard: an anchored glob, not a substring.
        ("a.csv", "*.csv", true),
        ("report.csvx", "*.csv", false),
        ("csv.report", "*.csv", false),
        ("a.csv.bak", "*.csv", false),
        // Anchoring at the front too.
        ("data.csv", "data*", true),
        ("mydata.csv", "data*", false),
        // `?` is exactly one character.
        ("f1.log", "?1.*", true),
        ("f10.log", "?1.*", false),
        ("file1.txt", "file?.txt", true),
        ("file10.txt", "file?.txt", false),
        // Bracket sets, ranges and negation.
        ("x1.dat", "x[12].dat", true),
        ("x2.dat", "x[12].dat", true),
        ("xy.dat", "x[12].dat", false),
        ("log7.txt", "log[0-9].txt", true),
        ("logx.txt", "log[0-9].txt", false),
        ("logx.txt", "log[!0-9].txt", true),
        ("log7.txt", "log[!0-9].txt", false),
        // Case-sensitive, POSIX default.
        ("notes.txt", "*.TXT", false),
        ("NOTES.TXT", "*.TXT", true),
        ("README.MD", "*.md", false),
        // No FNM_PERIOD: a leading dot is not special.
        (".hidden.csv", "*.csv", true),
        // A pattern with regex metacharacters is literal text.
        ("a+b.txt", "a+b.txt", true),
        ("axb.txt", "a+b.txt", false),
        ("v(1).log", "v(1).log", true),
        // `*` matches nothing at all.
        (".csv", "*.csv", true),
        // Escapes.
        ("a*b", #"a\*b"#, true),
        ("axb", #"a\*b"#, false),
        // Directories are entries too — nothing about the matcher excludes them.
        ("sub", "*", true),
        ("sub", "s*", true),
    ]

    @Test("Glob semantics", arguments: corpus)
    func matches(_ testCase: (name: String, pattern: String, expected: Bool)) {
        #expect(
            GlobMatcher.matches(testCase.name, pattern: testCase.pattern) == testCase.expected,
            "\(testCase.pattern) vs \(testCase.name)")
    }

    @Test("The portable matcher agrees with fnmatch(3)", arguments: corpus)
    func portableAgrees(_ testCase: (name: String, pattern: String, expected: Bool)) {
        // Windows has no fnmatch, so `GlobMatcher` carries a Swift fallback.
        // Two implementations of one contract drift the moment nothing
        // compares them — so this compares them, on every platform.
        #expect(
            GlobMatcher.matchesPortable(testCase.name, pattern: testCase.pattern) == testCase.expected,
            "\(testCase.pattern) vs \(testCase.name)")
    }

    @Test("An empty or absent pattern keeps everything")
    func emptyPatternKeepsEverything() {
        #expect(GlobMatcher.matches("anything.txt", pattern: ""))
        #expect(GlobMatcher.matches("anything.txt", pattern: String?.none))
    }
}

// MARK: - End to end

@Suite("List matching clause end to end", .serialized)
struct ListMatchingRuntimeTests {

    /// A directory holding the shapes the issue and the proposal talk about.
    /// Every count below is a property of exactly this fixture.
    ///
    ///     a.csv  b.csv  report.csvx  notes.txt  x1.dat  xy.dat  sub/  sub/deep.csv
    private static func fixture() throws -> String {
        let dir = NSTemporaryDirectory() + "aro-list-matching-\(UUID().uuidString)"
        let sub = dir + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        for name in ["a.csv", "b.csv", "report.csvx", "notes.txt", "x1.dat", "xy.dat"] {
            FileManager.default.createFile(atPath: dir + "/" + name, contents: Data("x".utf8))
        }
        FileManager.default.createFile(atPath: sub + "/deep.csv", contents: Data("x".utf8))
        return dir
    }

    /// Runs a program on an engine carrying the file-system service List needs.
    private static func run(_ source: String) async throws -> Response {
        let compiled = Compiler.compile(source)
        #expect(compiled.isSuccess, "\(compiled.diagnostics.map(\.message))")
        let engine = ExecutionEngine()
        await engine.register(service: AROFileSystemService(eventBus: .shared) as FileSystemService)
        let response = try await engine.execute(compiled.analyzedProgram)
        return response
    }

    /// Reads the integer the program returned.
    private static func asInt(_ response: Response) -> Int {
        guard let boxed = response.data["value"] else { return -1 }
        if let n: Int = boxed.get() { return n }
        if let s: String = boxed.get() { return Int(s) ?? -1 }
        if let d: Double = boxed.get() { return Int(d) }
        return -1
    }

    /// How many entries a List statement produced.
    ///
    /// Counted inside the program: `List` binds a lazy stream (ARO-0051), and
    /// `Compute … length` is what forces it, so the count is also proof the
    /// filtered stream is consumable end to end.
    private func count(_ listStatement: String, in dir: String) async throws -> Int {
        let response = try await Self.run("""
        (Application-Start: List Matching) {
            Create the <dir> with "\(dir)".
            \(listStatement)
            Compute the <found: length> from the <files>.
            Return an <OK: status> with <found>.
        }
        """)
        return Self.asInt(response)
    }

    @Test("matching \"*.csv\" excludes report.csvx — the substring hazard")
    func globIsNotSubstring() async throws {
        let dir = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // a.csv and b.csv. `Filter … contains ".csv"` would have kept
        // report.csvx and answered 3 — the bug the issue reports.
        let found = try await count(
            #"List the <files> from the <directory: dir> matching "*.csv"."#, in: dir)
        #expect(found == 2)
    }

    @Test("A `?` pattern matches exactly one character")
    func questionMarkPattern() async throws {
        let dir = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // x1.dat, not xy.dat — `?` is one character, and `y` is not `1`.
        let found = try await count(
            #"List the <files> from the <directory: dir> matching "?1.dat"."#, in: dir)
        #expect(found == 1)
    }

    @Test("A bracket pattern matches a character set")
    func bracketPattern() async throws {
        let dir = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // x1.dat only. A bracket pattern contains neither `*` nor `?`, so the
        // older qualifier spelling could not express it at all.
        let found = try await count(
            #"List the <files> from the <directory: dir> matching "x[0-9].dat"."#, in: dir)
        #expect(found == 1)
    }

    @Test("Matching is case-sensitive")
    func caseSensitive() async throws {
        let dir = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let found = try await count(
            #"List the <files> from the <directory: dir> matching "*.TXT"."#, in: dir)
        #expect(found == 0, "\"*.TXT\" matched notes.txt")
    }

    @Test("No match is an empty listing, not the whole directory")
    func noMatchIsEmpty() async throws {
        let dir = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let found = try await count(
            #"List the <files> from the <directory: dir> matching "*.nope"."#, in: dir)
        #expect(found == 0)
    }

    @Test("The glob may come from a variable")
    func globFromVariable() async throws {
        let dir = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let response = try await Self.run("""
        (Application-Start: List Matching) {
            Create the <dir> with "\(dir)".
            Create the <glob> with "*.dat".
            List the <files> from the <directory: dir> matching <glob>.
            Compute the <found: length> from the <files>.
            Return an <OK: status> with <found>.
        }
        """)
        #expect(Self.asInt(response) == 2, "x1.dat and xy.dat expected")
    }

    @Test("The glob filters directories as well as files")
    func filtersDirectories() async throws {
        let dir = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // `sub` is a directory and the only entry starting with `s`. A glob
        // filters entries, and a directory is an entry.
        let found = try await count(
            #"List the <files> from the <directory: dir> matching "s*"."#, in: dir)
        #expect(found == 1)
    }

    @Test("matching composes with recursively (ARO-0036 §6.4)")
    func matchingRecursively() async throws {
        let dir = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // a.csv, b.csv and sub/deep.csv.
        let found = try await count(
            #"List the <files> from the <directory: dir> matching "*.csv" recursively."#, in: dir)
        #expect(found == 3)
    }

    @Test("Trailing `recursively` alone still descends (ARO-0036 §6.3)")
    func recursivelyAlone() async throws {
        let dir = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Six files, the sub directory, and the file inside it.
        let found = try await count(
            "List the <files> from the <directory: dir> recursively.", in: dir)
        #expect(found == 8)
    }

    @Test("An unfiltered listing still returns everything")
    func unfilteredUnchanged() async throws {
        let dir = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Six files plus the sub directory — no clause, no filtering.
        let found = try await count(
            "List the <files> from the <directory: dir>.", in: dir)
        #expect(found == 7)
    }
}
