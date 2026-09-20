// ============================================================
// CheckSeparateApplicationsTests.swift
// ARO CLI — `aro check` on a directory of applications (GitLab #824)
// ============================================================
//
// `aro run` and `aro build` both refuse a path holding several applications
// and name a subdirectory to point at. `aro check` printed a note and exited
// 0, so a CI job running `aro check $DIR` passed on a path that cannot run:
//
//     $ aro check ./Examples/ModulesExample
//     note: ModulesExample contains 3 separate applications …
//     ✅ No issues found in 3 file(s)          # exit 0
//     $ aro run ./Examples/ModulesExample
//     Error: … contains 3 'Application-Start' feature sets …   # exit 1
//
// The exit code is the whole point of the check, so it is asserted here
// against the real binary rather than through the rule alone —
// `EntryPointCheckTests` covers the classification.

import Foundation
import Testing

@Suite("aro check on a directory of applications (GitLab #824)", .serialized)
struct CheckSeparateApplicationsTests {

    // MARK: - Harness

    private func findAroBinary() throws -> URL {
        var projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while !FileManager.default.fileExists(
            atPath: projectRoot.appendingPathComponent("Package.swift").path
        ) {
            let parent = projectRoot.deletingLastPathComponent()
            if parent == projectRoot {
                throw NSError(
                    domain: "CheckSeparateApplicationsTests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not find project root"]
                )
            }
            projectRoot = parent
        }

        for candidate in [".build/debug/aro", ".build/release/aro"] {
            let path = projectRoot.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: path.path) { return path }
        }
        throw NSError(
            domain: "CheckSeparateApplicationsTests", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "aro binary not found. Run 'swift build' first."]
        )
    }

    /// Run `aro check` with `arguments` and return its exit code and output.
    private func check(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = try findAroBinary()
        process.arguments = ["check"] + arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// A directory holding `applications` subdirectories, each a valid
    /// one-entry-point application.
    private func makeContainer(_ applications: [String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-824-\(UUID().uuidString)")
        for name in applications {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let source = """
            (Application-Start: \(name)) {
                Log "\(name) starting" to the <console>.
                Return an <OK: status> for the <startup>.
            }
            """
            try source.write(
                to: directory.appendingPathComponent("main.aro"),
                atomically: true, encoding: .utf8
            )
        }
        return root
    }

    // MARK: - The reported bug

    @Test("A directory of applications is an error, not a note")
    func containerIsAnError() throws {
        let root = try makeContainer(["Alpha", "Beta", "Gamma"])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try check([root.path])

        #expect(result.status == 1)
        #expect(result.output.contains("3 separate applications"))
        #expect(!result.output.contains("No issues found"))
    }

    @Test("The error names one application to check and offers --recursive")
    func errorIsActionable() throws {
        let root = try makeContainer(["Alpha", "Beta"])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try check([root.path])

        #expect(result.output.contains("aro check \(root.path)/Alpha"))
        #expect(result.output.contains("--recursive"))
    }

    @Test("One application inside the container still checks clean")
    func oneApplicationIsFine() throws {
        let root = try makeContainer(["Alpha", "Beta"])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try check([root.appendingPathComponent("Alpha").path])

        #expect(result.status == 0)
        #expect(result.output.contains("No issues found"))
    }

    // MARK: - --recursive

    @Test("--recursive checks each application and succeeds when all are clean")
    func recursiveChecksEach() throws {
        let root = try makeContainer(["Alpha", "Beta", "Gamma"])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try check(["--recursive", root.path])

        #expect(result.status == 0)
        #expect(result.output.contains("3 application(s) checked, no errors"))
    }

    @Test("--recursive fails when one application inside is broken")
    func recursiveReportsTheBrokenOne() throws {
        let root = try makeContainer(["Alpha", "Beta"])
        defer { try? FileManager.default.removeItem(at: root) }

        // Beta loses its entry point, which is an error for Beta alone.
        let beta = root.appendingPathComponent("Beta").appendingPathComponent("main.aro")
        try "(Handle Thing: Beta API) {\n    Return an <OK: status> for the <x>.\n}\n"
            .write(to: beta, atomically: true, encoding: .utf8)

        let result = try check(["--recursive", root.path])

        #expect(result.status == 1)
        #expect(result.output.contains("Beta"))
        // Alpha is still reported as fine — each application gets its own verdict.
        #expect(result.output.contains("1 of 2 application(s) have errors"))
    }

    @Test("--recursive reaches applications nested inside a container")
    func recursiveExpandsNestedContainers() throws {
        // `Examples/ModulesExample` shape: a container whose entries are
        // themselves a container of applications.
        let root = try makeContainer(["Alpha"])
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("Nested")
        for name in ["One", "Two"] {
            let directory = nested.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try "(Application-Start: \(name)) {\n    Return an <OK: status> for the <s>.\n}\n"
                .write(
                    to: directory.appendingPathComponent("main.aro"),
                    atomically: true, encoding: .utf8
                )
        }

        let result = try check(["--recursive", root.path])

        #expect(result.status == 0)
        // Alpha, Nested/One and Nested/Two — not Alpha and Nested.
        #expect(result.output.contains("3 application(s) checked, no errors"))
    }

    @Test("--recursive on a plain application checks just that one")
    func recursiveOnOneApplication() throws {
        let root = try makeContainer(["Alpha"])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try check(["--recursive", root.appendingPathComponent("Alpha").path])

        #expect(result.status == 0)
        #expect(result.output.contains("No issues found"))
    }

    @Test("--recursive needs a directory")
    func recursiveRejectsAFile() throws {
        let root = try makeContainer(["Alpha"])
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("Alpha").appendingPathComponent("main.aro")
        let result = try check(["--recursive", file.path])

        #expect(result.status != 0)
        #expect(result.output.contains("needs a directory"))
    }
}
