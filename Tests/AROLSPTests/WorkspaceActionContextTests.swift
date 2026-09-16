// ============================================================
// WorkspaceActionContextTests.swift
// AROLSP - cross-file Application.<Name> calls (#589)
// ============================================================

#if !os(Windows)
import Testing
import Foundation
@testable import AROLSP
@testable import AROParser

/// The LSP used to compile each document alone, so a call to an action
/// declared in a *sibling* file was reported as unknown — a red squiggle on
/// code that runs. These cover the two halves of the fix: the document
/// manager's action-context seam, and the workspace scan that fills it.
@Suite("LSP workspace action context (#589)")
struct WorkspaceActionContextTests {

    /// `caller.aro`: calls an action it does not itself declare.
    private let caller = """
    (Application-Start: Demo) {
        Application.Doubled the <r> from 21.
        Log <r> to the <console>.
        Return an <OK: status> for the <run>.
    }
    """

    /// `library.aro`: declares it.
    private let library = """
    (Doubled: Action takes <number>) {
        Extract the <n> from the <input: number>.
        Compute the <d> from <n> * 2.
        Return an <OK: status> with <d>.
    }
    """

    private func unknownActionErrors(_ result: CompilationResult?) -> [Diagnostic] {
        (result?.diagnostics ?? []).filter {
            $0.severity == .error && $0.message.contains("Unknown user-defined action")
        }
    }

    // MARK: - The document manager's seam

    @Test("Without workspace context the cross-file call is reported unknown")
    func withoutContext() {
        let manager = DocumentManager()
        let state = manager.open(uri: "file:///caller.aro", content: caller, version: 1)

        let errors = unknownActionErrors(state.compilationResult)
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("Application.Doubled") == true)
    }

    @Test("With workspace context the same call compiles clean")
    func withContext() {
        let manager = DocumentManager()
        manager.declaredActionsProvider = { UserActionRegistry.declared(inSources: [library]) }

        let state = manager.open(uri: "file:///caller.aro", content: caller, version: 1)
        #expect(unknownActionErrors(state.compilationResult).isEmpty)
    }

    @Test("Context applies to updates, not only the initial open")
    func contextAppliesToUpdates() {
        let manager = DocumentManager()
        manager.declaredActionsProvider = { UserActionRegistry.declared(inSources: [library]) }
        let uri = "file:///caller.aro"

        _ = manager.open(uri: uri, content: "(* empty *)\n", version: 1)
        let updated = manager.update(uri: uri, content: caller, version: 2)

        #expect(updated != nil)
        // Hoisted: `#expect`'s property-access rewriting trips over the `?`
        // inside the call argument.
        let errors = unknownActionErrors(updated?.compilationResult)
        #expect(errors.isEmpty)
    }

    @Test("A genuinely undeclared action is still reported with context present")
    func contextDoesNotSuppressRealErrors() {
        let manager = DocumentManager()
        manager.declaredActionsProvider = { UserActionRegistry.declared(inSources: [library]) }

        let source = caller.replacingOccurrences(
            of: "Application.Doubled", with: "Application.Tripled"
        )
        let state = manager.open(uri: "file:///caller.aro", content: source, version: 1)

        let errors = unknownActionErrors(state.compilationResult)
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("Application.Tripled") == true)
    }

    // MARK: - The workspace scan that fills it

    /// Writes `caller.aro` and `library.aro` into a fresh directory, plus a
    /// decoy under `.build/` that must not be scanned.
    private func makeWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-589-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try caller.write(to: root.appendingPathComponent("caller.aro"), atomically: true, encoding: .utf8)

        let build = root.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try "(Stale: Action) {\n    Return an <OK: status> for the <x>.\n}\n"
            .write(to: build.appendingPathComponent("stale.aro"), atomically: true, encoding: .utf8)

        return root
    }

    @Test("Scanning a workspace root finds an action declared in a sibling file")
    func scanFindsSibling() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try library.write(
            to: root.appendingPathComponent("library.aro"), atomically: true, encoding: .utf8
        )

        let state = AROLanguageServer.WorkspaceState()
        state.setRoots([root])

        let registry = state.currentDeclaredActions()
        #expect(registry?.info(for: "Doubled") != nil)
    }

    @Test("Build directories are not scanned")
    func skipsBuildDirectory() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = AROLanguageServer.WorkspaceState()
        state.setRoots([root])

        // `caller.aro` alone is scanned, so the registry exists but is empty
        // of the decoy `.build/stale.aro` declares.
        let registry = state.currentDeclaredActions()
        #expect(registry != nil)
        #expect(registry?.info(for: "Stale") == nil)
    }

    @Test("Invalidating picks up a file added after the first scan")
    func invalidationPicksUpNewFile() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let state = AROLanguageServer.WorkspaceState()
        state.setRoots([root])
        #expect(state.currentDeclaredActions()?.info(for: "Doubled") == nil)

        try library.write(
            to: root.appendingPathComponent("library.aro"), atomically: true, encoding: .utf8
        )

        // Still cached — this is the point of the cache, and of the save hook.
        #expect(state.currentDeclaredActions()?.info(for: "Doubled") == nil)

        state.invalidateDeclaredActions()
        #expect(state.currentDeclaredActions()?.info(for: "Doubled") != nil)
    }

    @Test("With no workspace root there is no context to speak for the file")
    func noRootsNoContext() {
        let state = AROLanguageServer.WorkspaceState()
        #expect(state.currentDeclaredActions() == nil)
    }
}
#endif
