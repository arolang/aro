// ============================================================
// PathAndFileMetadataTests.swift
// ARO Runtime — path operations, permissions, touch
// ARO-0036 §9 / §10, GitLab #861
// ============================================================
//
// `Stat` read permissions from the start and nothing could set them. There was
// no path vocabulary at all, so joining a directory to a filename was string
// concatenation — which gets `"a/" + "/b"` wrong, and nobody notices until a
// path arrives with a trailing slash.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Paths and file metadata (#861)")
struct PathAndFileMetadataTests {

    // MARK: - Path qualifiers

    private func compute(
        _ qualifier: String,
        on input: any Sendable,
        with parameters: (any Sendable)? = nil
    ) throws -> any Sendable {
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: input)
        if let parameters { context.bind("_with_", value: parameters) }
        return try ComputeAction().executeSynchronously(
            result: ResultDescriptor(base: "out", specifiers: [qualifier], span: span),
            object: ObjectDescriptor(preposition: .from, base: "input", specifiers: [], span: span),
            context: context)
    }

    @Test("basename is the last component")
    func basename() throws {
        #expect(try compute("basename", on: "/var/data/report.csv") as? String == "report.csv")
        #expect(try compute("basename", on: "report.csv") as? String == "report.csv")
    }

    @Test("a trailing slash is not a component")
    func basenameIgnoresTrailingSlash() throws {
        // What every shell means by it: the basename of `/var/data/` is `data`.
        #expect(try compute("basename", on: "/var/data/") as? String == "data")
    }

    @Test("dirname is everything before it")
    func dirname() throws {
        #expect(try compute("dirname", on: "/var/data/report.csv") as? String == "/var/data")
        #expect(try compute("dirname", on: "/report.csv") as? String == "/")
    }

    @Test("a bare filename is in `.`, not in nothing")
    func dirnameOfBareName() throws {
        // `.` composes with path-join; `""` would produce `/report.csv`.
        #expect(try compute("dirname", on: "report.csv") as? String == ".")
    }

    @Test("extension comes back without the dot")
    func fileExtension() throws {
        // Every use of it — a comparison, building a new name — would
        // otherwise have to strip one.
        #expect(try compute("extension", on: "/var/report.csv") as? String == "csv")
        #expect(try compute("extension", on: "archive.tar.gz") as? String == "gz")
    }

    @Test("a name with no dot has no extension")
    func noExtension() throws {
        #expect(try compute("extension", on: "Makefile") as? String == "")
        #expect(try compute("extension", on: "report.") as? String == "")
    }

    @Test("a dotfile is a name, not an extension")
    func dotfileHasNoExtension() throws {
        // The classic off-by-one here: `.gitignore` is not a file of type
        // `gitignore`.
        #expect(try compute("extension", on: ".gitignore") as? String == "")
        #expect(try compute("stem", on: ".gitignore") as? String == ".gitignore")
    }

    @Test("stem is the basename without the extension")
    func stem() throws {
        #expect(try compute("stem", on: "/var/data/report.csv") as? String == "report")
        #expect(try compute("stem", on: "Makefile") as? String == "Makefile")
        #expect(try compute("stem", on: "archive.tar.gz") as? String == "archive.tar")
    }

    @Test("basename, stem and extension agree with each other")
    func pathPartsCompose() throws {
        // The set has to be closed: a rename that keeps the name and changes
        // the type needs all three to line up.
        let path = "/srv/data/report.csv"
        let base = try #require(compute("basename", on: path) as? String)
        let stem = try #require(compute("stem", on: path) as? String)
        let ext = try #require(compute("extension", on: path) as? String)
        #expect(base == "\(stem).\(ext)")
    }

    // MARK: - path-join

    @Test("join uses exactly one separator, however the pieces are written")
    func joinNormalisesSeparators() throws {
        // The case the issue names: string concatenation gets this wrong and
        // nobody notices until a path has a trailing slash.
        #expect(try compute("path-join", on: "uploads/", with: "/photo.png") as? String
                == "uploads/photo.png")
        #expect(try compute("path-join", on: "uploads", with: "photo.png") as? String
                == "uploads/photo.png")
        #expect(try compute("path-join", on: "uploads//", with: "//photo.png") as? String
                == "uploads/photo.png")
    }

    @Test("an absolute left side stays absolute")
    func joinKeepsLeadingSlash() throws {
        #expect(try compute("path-join", on: "/srv/uploads", with: "photo.png") as? String
                == "/srv/uploads/photo.png")
    }

    @Test("an absolute RIGHT side does not reset the path")
    func joinDoesNotResetOnAbsoluteComponent() throws {
        // Deliberately unlike Python's os.path.join, and the reason is the
        // call this is for: joining a trusted directory to an untrusted name.
        // A join that a leading slash can turn into "anywhere on the
        // filesystem" is a path traversal waiting to be written.
        #expect(try compute("path-join", on: "/uploads", with: "/etc/passwd") as? String
                == "/uploads/etc/passwd")
    }

    @Test("several components join at once")
    func joinMultiple() throws {
        #expect(try compute("path-join", on: "a", with: ["b", "c/d"]) as? String == "a/b/c/d")
    }

    @Test("a list input joins its own elements")
    func joinListInput() throws {
        #expect(try compute("path-join", on: ["srv", "data", "x.csv"]) as? String
                == "srv/data/x.csv")
    }

    // MARK: - absolute

    @Test("absolute resolves . and .. lexically")
    func absoluteResolvesDots() throws {
        #expect(try compute("absolute", on: "/var/./data/../data/x.txt") as? String
                == "/var/data/x.txt")
    }

    @Test("absolute leaves an already-absolute path rooted")
    func absoluteIsIdempotent() throws {
        let once = try #require(compute("absolute", on: "/srv/x.txt") as? String)
        let twice = try #require(compute("absolute", on: once) as? String)
        #expect(once == "/srv/x.txt")
        #expect(twice == once)
    }

    @Test("a relative path is resolved against the working directory")
    func absoluteRootsRelativePaths() throws {
        let resolved = try #require(compute("absolute", on: "x.txt") as? String)
        #expect(resolved.hasPrefix("/"))
        #expect(resolved.hasSuffix("/x.txt"))
    }

    @Test("`..` above the root stops at the root rather than escaping it")
    func absoluteClampsAtRoot() throws {
        #expect(try compute("absolute", on: "/../../etc") as? String == "/etc")
    }

    // MARK: - The catalogs agree

    @Test("the parser's catalog knows every path qualifier")
    func catalogAgrees() {
        // `aro check` never loads the runtime, so a green check has to mean
        // the qualifier exists.
        for name in ["basename", "dirname", "extension", "stem", "absolute", "path-join"] {
            #expect(ComputeQualifierCatalog.builtIns.contains(name), "missing \(name)")
        }
    }

    // MARK: - FileMode

    @Test("an octal mode parses, with or without the leading zero")
    func octalModes() {
        #expect(FileMode.parse("755")?.bits == 0o755)
        #expect(FileMode.parse("0644")?.bits == 0o644)
        #expect(FileMode.parse("600")?.bits == 0o600)
    }

    @Test("the symbolic form Stat prints parses back")
    func symbolicModes() {
        // The round trip is the point: reading the mode off one file and
        // applying it to another only works if the setter takes what the
        // getter produces.
        #expect(FileMode.parse("rwxr-xr-x")?.bits == 0o755)
        #expect(FileMode.parse("rw-r--r--")?.bits == 0o644)
        #expect(FileMode.parse("---------")?.bits == 0)
        // And the `ls -l` form people paste, with the leading type character.
        #expect(FileMode.parse("-rwxr-xr-x")?.bits == 0o755)
    }

    @Test("a mode round-trips through both renderings")
    func modeRoundTrip() throws {
        let mode = try #require(FileMode.parse("750"))
        #expect(mode.symbolic == "rwxr-x---")
        #expect(mode.octal == "750")
        #expect(FileMode.parse(mode.symbolic)?.bits == mode.bits)
        #expect(FileMode.parse(mode.octal)?.bits == mode.bits)
    }

    @Test("something that is not a mode is rejected rather than guessed at")
    func badModes() {
        // A chmod that silently did something other than what was written is
        // the one outcome worth ruling out.
        #expect(FileMode.parse("799") == nil)      // not octal
        #expect(FileMode.parse("rwx") == nil)      // too short
        #expect(FileMode.parse("hello") == nil)
        #expect(FileMode.parse("") == nil)
        #expect(FileMode.parse("rwxr-xr-y") == nil)
    }

    // MARK: - Permissions and touch, against a real file

    #if !os(Windows)
    @Test("Configure sets permissions and reports the previous mode")
    func configurePermissions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-861-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("run.sh")
        FileManager.default.createFile(atPath: file.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        let service = AROFileSystemService(eventBus: EventBus())
        let previous = try await service.setPermissions(path: file.path,
                                                        mode: #require(FileMode.parse("755")))
        #expect(previous?.octal == "644")

        let info = try await service.stat(path: file.path)
        #expect(info.permissions == "rwxr-xr-x")
    }

    @Test("setting permissions on a missing file fails rather than passing")
    func permissionsOnMissingFile() async {
        let service = AROFileSystemService(eventBus: EventBus())
        await #expect(throws: (any Error).self) {
            _ = try await service.setPermissions(
                path: "/nonexistent/aro-861/nope", mode: FileMode(bits: 0o755)!)
        }
    }
    #endif

    @Test("touch creates a file, then updates it")
    func touchCreatesThenStamps() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-861-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("stamp")
        let service = AROFileSystemService(eventBus: EventBus())

        #expect(service.exists(path: file.path) == false)
        try await service.touch(path: file.path)
        #expect(service.exists(path: file.path))

        // The half that had no spelling at all: stamping a file that is
        // already there.
        let before = try await service.stat(path: file.path).modified
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try await service.touch(path: file.path)
        let after = try await service.stat(path: file.path).modified
        #expect(before != after)
    }

    @Test("Touch is its own verb, and Make no longer claims it")
    func touchIsItsOwnAction() {
        // It used to be a verb on MakeAction, which decided file-vs-directory
        // from the *result* name — so `Touch the <t> for the <file: "./x">.`
        // created a directory called `file`.
        #expect(TouchAction.verbs.contains("touch"))
        #expect(MakeAction.verbs.contains("touch") == false)
        #expect(MakeAction.verbs.contains("mkdir"))
    }
}
