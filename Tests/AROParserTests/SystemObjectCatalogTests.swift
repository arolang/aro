// ============================================================
// SystemObjectCatalogTests.swift
// AROParser — framework-provided object recognition (GitLab #478)
// ============================================================

import Testing
@testable import AROParser

@Suite("System Object Catalog")
struct SystemObjectCatalogTests {

    /// Warnings that indicate the analyser mistook a system object for an
    /// undefined user variable.
    private func falsePositiveWarnings(_ source: String) -> [String] {
        let result = Compiler.compile(source)
        return result.diagnostics
            .map(\.message)
            .filter {
                $0.contains("used before definition")
                    || $0.contains("is not published by any feature set")
            }
    }

    // MARK: - The three names that were missing

    @Test("<command: …> is not reported as undefined")
    func testCommandQualifier() {
        let warnings = falsePositiveWarnings("""
        (Application-Start: T) {
            Exec the <r> for the <command: "true">.
            Log <r> to the <console>.
            Return an <OK: status> for the <t>.
        }
        """)

        #expect(warnings.isEmpty, "unexpected: \(warnings)")
    }

    @Test("<url: …> is not reported as undefined")
    func testURLQualifier() {
        let warnings = falsePositiveWarnings("""
        (Application-Start: T) {
            Request the <resp> from the <url: "https://example.com">.
            Log <resp> to the <console>.
            Return an <OK: status> for the <t>.
        }
        """)

        #expect(warnings.isEmpty, "unexpected: \(warnings)")
    }

    @Test("<destination: …> is not reported as undefined")
    func testDestinationQualifier() {
        let warnings = falsePositiveWarnings("""
        (Application-Start: T) {
            Create the <src> with "./a.txt".
            Create the <dst> with "./b.txt".
            Copy the <file: src> to the <destination: dst>.
            Return an <OK: status> for the <t>.
        }
        """)

        #expect(warnings.isEmpty, "unexpected: \(warnings)")
    }

    // MARK: - Catalog completeness

    @Test("Every catalogued name is recognised, case-insensitively")
    func testEveryCatalogEntryIsRecognised() {
        for name in SystemObjectCatalog.names {
            #expect(SystemObjectCatalog.isSystemObject(name), "\(name) not recognised")
            #expect(
                SystemObjectCatalog.isSystemObject(name.uppercased()),
                "\(name) not recognised when uppercased"
            )
        }
    }

    @Test("Filesystem bases used by file actions are all catalogued")
    func testFilesystemBasesCatalogued() {
        // Mirrors the `excluding:` sets in ARORuntime's FileActions. If a file
        // action starts excluding a new base, it belongs here too.
        for base in ["file", "directory", "path", "destination"] {
            #expect(SystemObjectCatalog.isSystemObject(base), "\(base) not catalogued")
        }
    }

    @Test("Repository names are provided by suffix")
    func testRepositorySuffix() {
        #expect(SystemObjectCatalog.isSystemObject("user-repository"))
        #expect(SystemObjectCatalog.isSystemObject("Order-Repository"))
        #expect(!SystemObjectCatalog.isSystemObject("repositoryish"))
    }

    // MARK: - Genuine warnings still fire

    // NOTE: avoid hyphenated placeholder names here — `never-defined` fails to
    // lex, because `defined` is tokenised as a reserved word after the hyphen.
    @Test("A genuinely undefined variable is still reported")
    func testGenuineForwardReferenceStillWarns() {
        let warnings = falsePositiveWarnings("""
        (Application-Start: T) {
            Compute the <doubled> from <missingvalue> * 2.
            Return an <OK: status> for the <t>.
        }
        """)

        #expect(warnings.contains { $0.contains("missingvalue") })
    }

    @Test("A name that merely resembles a system object is still reported")
    func testNearMissStillWarns() {
        let warnings = falsePositiveWarnings("""
        (Application-Start: T) {
            Compute the <x> from <commander> * 2.
            Return an <OK: status> for the <t>.
        }
        """)

        #expect(warnings.contains { $0.contains("commander") })
    }
}
