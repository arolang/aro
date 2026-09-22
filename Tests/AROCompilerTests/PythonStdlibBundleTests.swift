// ============================================================
// PythonStdlibBundleTests.swift
// AROCompiler — what the binary carries (GitLab #856)
// ============================================================

import Testing
import Foundation
@testable import AROCompiler

@Suite("Python stdlib bundle")
struct PythonStdlibBundleTests {

    // MARK: - Selection

    @Test func ordinaryModulesAreCarried() {
        #expect(PythonStdlibBundle.shouldInclude(relativePath: "json/decoder.py"))
        #expect(PythonStdlibBundle.shouldInclude(relativePath: "encodings/utf_8.py"))
        #expect(PythonStdlibBundle.shouldInclude(relativePath: "os.py"))
        // Compiled extensions are the interpreter's own and must travel.
        #expect(PythonStdlibBundle.shouldInclude(
            relativePath: "lib-dynload/_json.cpython-312-darwin.so"))
    }

    @Test func cpythonsOwnTestSuiteIsNotCarried() {
        // Tens of megabytes that no running program imports.
        #expect(!PythonStdlibBundle.shouldInclude(relativePath: "test"))
        #expect(!PythonStdlibBundle.shouldInclude(
            relativePath: "test/test_json/test_decode.py"))
        #expect(!PythonStdlibBundle.shouldInclude(
            relativePath: "json/tests/helper.py"))
    }

    @Test func theDisplayDependentModulesAreNotCarried() {
        // A headless target has no Tcl/Tk, so these could not run there
        // even if they were carried.
        #expect(!PythonStdlibBundle.shouldInclude(relativePath: "tkinter/ttk.py"))
        #expect(!PythonStdlibBundle.shouldInclude(relativePath: "idlelib/run.py"))
        #expect(!PythonStdlibBundle.shouldInclude(relativePath: "turtledemo/x.py"))
    }

    @Test func bytecodeIsNotCarried() {
        // Regenerated on the target, and stamped with build-machine
        // paths that would be wrong there anyway.
        #expect(!PythonStdlibBundle.shouldInclude(
            relativePath: "json/__pycache__/decoder.cpython-312.pyc"))
        #expect(!PythonStdlibBundle.shouldInclude(relativePath: "os.pyc"))
        #expect(!PythonStdlibBundle.shouldInclude(relativePath: "os.pyo"))
    }

    @Test func sitePackagesIsNotCarried() {
        // The decisive exclusion. Copying whatever is installed on the
        // build machine is how a binary acquires dependencies nobody
        // declared — the same mistake as borrowing its interpreter.
        #expect(!PythonStdlibBundle.shouldInclude(
            relativePath: "site-packages/requests/api.py"))
        #expect(!PythonStdlibBundle.shouldInclude(
            relativePath: "dist-packages/six.py"))
    }

    @Test func buildLeftoversAreNotCarried() {
        #expect(!PythonStdlibBundle.shouldInclude(
            relativePath: "config-3.12-darwin/libpython3.12.a"))
        #expect(!PythonStdlibBundle.shouldInclude(
            relativePath: "config-3.12-darwin/python.o"))
    }

    @Test func anEmptyPathIsNotCarried() {
        #expect(!PythonStdlibBundle.shouldInclude(relativePath: ""))
    }

    @Test func aModuleWhoseNameMerelyContainsAnExcludedWordIsCarried() {
        // `testing.py` is not `test/`, and `contest.py` is not either.
        // Excluding by substring would quietly drop real modules.
        #expect(PythonStdlibBundle.shouldInclude(relativePath: "testing.py"))
        #expect(PythonStdlibBundle.shouldInclude(relativePath: "unittest/case.py"))
        #expect(PythonStdlibBundle.shouldInclude(relativePath: "contest.py"))
    }

    // MARK: - Where it lands at run time

    @Test func theStdlibSitsBesideTheExecutable() {
        // Not a temp directory: /tmp is often mounted noexec, which the
        // stdlib's C extensions cannot survive, and a long-running
        // service can have its temp directory cleaned underneath it.
        let home = PythonStdlibBundle.pythonHome(
            besideExecutable: "/opt/app/myapp", version: "3.12")
        #expect(home == "/opt/app/aro-python3.12")
    }

    @Test func theDirectoryNameCarriesTheVersion() {
        // Two ARO binaries built against different Pythons can sit in
        // one directory without fighting over it.
        #expect(PythonStdlibBundle.runtimeDirectoryName(version: "3.12")
                != PythonStdlibBundle.runtimeDirectoryName(version: "3.13"))
    }

    // MARK: - Staging

    @Test func stagingCopiesWhatBelongsAndSkipsWhatDoesNot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-stdlib-\(UUID().uuidString)")
        let src = root.appendingPathComponent("src")
        let dst = root.appendingPathComponent("dst")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }

        func write(_ rel: String, _ text: String = "x") throws {
            let f = src.appendingPathComponent(rel)
            try fm.createDirectory(at: f.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try Data(text.utf8).write(to: f)
        }
        try write("os.py", "import sys")
        try write("json/decoder.py")
        try write("encodings/utf_8.py")
        try write("test/test_os.py")
        try write("json/__pycache__/decoder.cpython-312.pyc")
        try write("site-packages/requests/api.py")

        let report = try PythonStdlibBundle.stage(stdlibPath: src.path,
                                                  into: dst.path)
        #expect(report.fileCount == 3)
        #expect(fm.fileExists(atPath: dst.appendingPathComponent("os.py").path))
        #expect(fm.fileExists(
            atPath: dst.appendingPathComponent("json/decoder.py").path))
        #expect(fm.fileExists(
            atPath: dst.appendingPathComponent("encodings/utf_8.py").path))
        // And the three exclusions really did not travel.
        #expect(!fm.fileExists(atPath: dst.appendingPathComponent("test").path))
        #expect(!fm.fileExists(
            atPath: dst.appendingPathComponent("json/__pycache__").path))
        #expect(!fm.fileExists(
            atPath: dst.appendingPathComponent("site-packages").path))
    }

    @Test func stagingReportsWhatItCarried() throws {
        // The size of an embedded Python is the cost of this feature.
        // It belongs in the build's output, not in a surprise at the end.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-stdlib-\(UUID().uuidString)")
        let src = root.appendingPathComponent("src")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data(String(repeating: "a", count: 500).utf8)
            .write(to: src.appendingPathComponent("big.py"))

        let report = try PythonStdlibBundle.stage(
            stdlibPath: src.path,
            into: root.appendingPathComponent("dst").path)
        #expect(report.fileCount == 1)
        #expect(report.byteCount == 500)
    }

    @Test func stagingAnAbsentStdlibIsNotACrash() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-stdlib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try PythonStdlibBundle.stage(
            stdlibPath: root.appendingPathComponent("nope").path,
            into: root.appendingPathComponent("dst").path)
        #expect(report.fileCount == 0)
    }
}
