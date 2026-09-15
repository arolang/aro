// ============================================================
// ConfigureRebindHintTests.swift
// ARO Parser Tests - the hint a rejected Configure gets (GitLab #564)
// ============================================================
//
// Setting two repository constraints, as Chapter 36 documents, is rejected:
//
//     Configure the <cache-repository: ttl> with 60.
//     Configure the <cache-repository: maxSize> with 500.
//
// The immutability check keys on the result *base* and ignores the qualifier,
// so two settings on one repository read as a rebinding of the repository
// itself. The check is right to fire — `Configure` genuinely binds its result —
// but the hint it gave was nonsense here:
//
//     hint: Example: <Configure> the <cache-repository-updated> with the <_expression_>
//
// `cache-repository-updated` is a *different repository*, so following the
// advice would compile and configure the wrong thing. The object form sets
// every setting at once and is what to write.

import Testing
@testable import AROParser

@Suite("Configure rebinding hint (GitLab #564)")
struct ConfigureRebindHintTests {

    private func diagnostics(_ source: String) -> [Diagnostic] {
        Compiler().compile(source).diagnostics
    }

    private static let twoSettings = """
    (Test: Feature) {
        Configure the <cache-repository: ttl> with 60.
        Configure the <cache-repository: maxSize> with 500.
        Return an <OK: status> for the <test>.
    }
    """

    // MARK: - The hint

    @Test("The hint points at the object form, not an invented repository name")
    func hintNamesTheObjectForm() {
        let errors = diagnostics(Self.twoSettings).filter { $0.severity == .error }
        #expect(errors.count == 1)

        let hints = errors.first?.hints ?? []
        #expect(hints.contains { $0.contains("every setting at once") },
                "hints were: \(hints)")
        #expect(hints.contains { $0.contains("with { setting: value") },
                "hints were: \(hints)")
    }

    @Test("It no longer invents a `-updated` repository")
    func hintDoesNotInventARepository() {
        let errors = diagnostics(Self.twoSettings).filter { $0.severity == .error }
        let hints = errors.first?.hints ?? []

        // Following this would have configured a different repository.
        #expect(!hints.contains { $0.contains("cache-repository-updated") },
                "hints were: \(hints)")
    }

    @Test("The hint names the repository the statement actually configures")
    func hintNamesTheRealRepository() {
        let errors = diagnostics(Self.twoSettings).filter { $0.severity == .error }
        let hints = errors.first?.hints ?? []
        #expect(hints.contains { $0.contains("<cache-repository>") }, "hints were: \(hints)")
    }

    // MARK: - The object form is accepted

    @Test("One Configure with every setting in an object is accepted")
    func objectFormIsAccepted() {
        let errors = diagnostics("""
        (Test: Feature) {
            Configure the <cache-repository> with { ttl: 60, maxSize: 500 }.
            Return an <OK: status> for the <test>.
        }
        """).filter { $0.severity == .error }

        #expect(errors.isEmpty, "\(errors)")
    }

    @Test("A single qualified Configure is still fine — one setting rebinds nothing")
    func singleSettingIsAccepted() {
        let errors = diagnostics("""
        (Test: Feature) {
            Configure the <session-repository: ttl> with 300.
            Return an <OK: status> for the <test>.
        }
        """).filter { $0.severity == .error }

        #expect(errors.isEmpty, "\(errors)")
    }

    @Test("Configuring two different repositories is fine")
    func differentRepositoriesAreFine() {
        let errors = diagnostics("""
        (Test: Feature) {
            Configure the <cache-repository: ttl> with 60.
            Configure the <session-repository: ttl> with 300.
            Return an <OK: status> for the <test>.
        }
        """).filter { $0.severity == .error }

        #expect(errors.isEmpty, "\(errors)")
    }

    // MARK: - Other verbs keep the generic advice

    @Test("A value rebinding still gets the new-name advice, which is right there")
    func otherVerbsKeepTheGenericHint() {
        let errors = diagnostics("""
        (Test: Feature) {
            Make the <value> with "first".
            Make the <value> with "second".
            Return an <OK: status> for the <test>.
        }
        """).filter { $0.severity == .error }

        let hints = errors.first?.hints ?? []
        #expect(hints.contains { $0.contains("value-updated") }, "hints were: \(hints)")
        #expect(!hints.contains { $0.contains("every setting at once") })
    }
}
