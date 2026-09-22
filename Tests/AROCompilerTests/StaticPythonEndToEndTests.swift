// ============================================================
// StaticPythonEndToEndTests.swift
// AROCompiler — a real distribution on a real disk (GitLab #856)
// ============================================================
//
// The other suites for #856 run against fixtures: a probe made of
// closures, a policy that takes its inputs as arguments. That is the
// right shape for the rules, but it proves nothing about the parts
// that touch a filesystem — the archive magic read off a real file,
// the symlink resolution in staging, the layout the binary will
// actually find beside itself.
//
// So this suite builds a plausible CPython distribution in a temporary
// directory, points `locate` at it through the environment exactly as
// a build would, and walks the result all the way to a staged
// PYTHONHOME. Everything but the link step, which needs a real
// libpython and is covered by the integration examples.

import Testing
import Foundation
@testable import AROCompiler

@Suite("Static Python, end to end")
struct StaticPythonEndToEndTests {

    /// Build a distribution on disk: a real `ar` archive, a stdlib with
    /// `encodings/` (which `Py_Initialize` requires), and the kinds of
    /// junk a real tree carries.
    private func makeDistribution(version: String = "3.12") throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-856-\(UUID().uuidString)")
        let lib = root.appendingPathComponent("lib")
        let stdlib = lib.appendingPathComponent("python\(version)")

        for dir in ["encodings", "json", "test", "__pycache__", "site-packages"] {
            try fm.createDirectory(at: stdlib.appendingPathComponent(dir),
                                   withIntermediateDirectories: true)
        }

        // A real static archive, recognised by its magic and nothing else.
        let archive = lib.appendingPathComponent("libpython\(version).a")
        try Data("!<arch>\n/  padding, not that anything reads it".utf8)
            .write(to: archive)

        // Stdlib contents: what should travel, and what should not.
        try Data("# os\n".utf8).write(to: stdlib.appendingPathComponent("os.py"))
        try Data("".utf8).write(to: stdlib.appendingPathComponent("os.pyc"))
        try Data("# codec\n".utf8)
            .write(to: stdlib.appendingPathComponent("encodings/__init__.py"))
        try Data("# json\n".utf8)
            .write(to: stdlib.appendingPathComponent("json/__init__.py"))
        try Data("# their test\n".utf8)
            .write(to: stdlib.appendingPathComponent("test/test_os.py"))
        try Data("".utf8)
            .write(to: stdlib.appendingPathComponent("__pycache__/os.cpython-312.pyc"))
        try Data("# someone's numpy\n".utf8)
            .write(to: stdlib.appendingPathComponent("site-packages/numpy.py"))

        return root
    }

    @Test func aDistributionOnDiskIsFoundThroughTheEnvironment() throws {
        let root = try makeDistribution()
        defer { try? FileManager.default.removeItem(at: root) }

        let found = StaticPythonDistribution.locate(
            environment: [StaticPythonDistribution.environmentVariable: root.path])

        guard case .found(let dist) = found else {
            Issue.record("not found: \(found)")
            return
        }
        #expect(dist.version == "3.12")
        #expect(dist.archivePath.hasSuffix("lib/libpython3.12.a"))
        #expect(dist.stdlibPath.hasSuffix("lib/python3.12"))
    }

    /// The decoy that motivates the whole check: a file named
    /// `libpython3.12.a` that is not an archive. python.org ships
    /// exactly this, as a symlink to the framework binary.
    @Test func aFileNamedLikeAnArchiveButIsNotIsRejected() throws {
        let root = try makeDistribution()
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = root.appendingPathComponent("lib/libpython3.12.a")
        try FileManager.default.removeItem(at: archive)
        // Mach-O, near enough: anything whose first bytes are not `!<arch>\n`.
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01])
            .write(to: archive)

        let found = StaticPythonDistribution.locate(
            environment: [StaticPythonDistribution.environmentVariable: root.path])
        #expect(found == .rejected(.archiveIsDynamic(path: archive.path)))
    }

    @Test func theDistributionCarriesItsOwnLinkerFlags() throws {
        let root = try makeDistribution()
        defer { try? FileManager.default.removeItem(at: root) }

        guard case .found(let dist) = StaticPythonDistribution.locate(
            environment: [StaticPythonDistribution.environmentVariable: root.path])
        else { Issue.record("not found"); return }

        // The archive by absolute path, never `-lpython3.12`: a search by
        // name is how a build finds the dynamic library it was avoiding.
        #expect(dist.linkerFlags.first == dist.archivePath)
        #expect(!dist.linkerFlags.contains("-lpython3.12"))
        #expect(dist.linkerFlags.contains("-lm"))
    }

    /// The whole chain: find it, decide on it, stage it, and check that
    /// what landed is what an embedded interpreter needs.
    @Test func findingLeadsToAStagedPythonHome() throws {
        let root = try makeDistribution()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        let located = StaticPythonDistribution.locate(
            environment: [StaticPythonDistribution.environmentVariable: root.path])
        let decision = EmbeddedPythonPolicy.decide(
            plugins: ["markdown"],
            linkMode: .staticLink,
            distribution: located,
            buildMachinePython: nil,
            overrideEnabled: false)

        guard case .embedStatically(let dist) = decision else {
            Issue.record("expected to embed, got \(decision)")
            return
        }

        // Where the binary will look: beside itself.
        let binary = root.appendingPathComponent("build/MyApp")
        try fm.createDirectory(at: binary.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let home = PythonStdlibBundle.pythonHome(besideExecutable: binary.path,
                                                 version: dist.version)
        #expect(home.hasSuffix("build/aro-python3.12"))

        let report = try PythonStdlibBundle.stage(stdlibPath: dist.stdlibPath,
                                                  into: home)

        #expect(fm.fileExists(atPath: home + "/encodings/__init__.py"))
        #expect(fm.fileExists(atPath: home + "/json/__init__.py"))
        #expect(fm.fileExists(atPath: home + "/os.py"))
        // CPython's own test suite, the build machine's packages, and
        // compiled caches stay behind.
        #expect(!fm.fileExists(atPath: home + "/test/test_os.py"))
        #expect(!fm.fileExists(atPath: home + "/site-packages/numpy.py"))
        #expect(!fm.fileExists(atPath: home + "/os.pyc"))
        #expect(!fm.fileExists(atPath: home + "/__pycache__"))

        #expect(report.fileCount == 3)
        #expect(report.byteCount > 0)
        #expect(report.destination == home)
    }
}
