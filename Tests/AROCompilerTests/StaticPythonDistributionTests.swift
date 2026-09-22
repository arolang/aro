// ============================================================
// StaticPythonDistributionTests.swift
// AROCompiler — finding a CPython that can be embedded (GitLab #856)
// ============================================================

import Testing
import Foundation
@testable import AROCompiler

@Suite("Static Python distribution")
struct StaticPythonDistributionTests {

    /// A fixture filesystem: directories, files, and which files are
    /// real archives. Everything this type asks about, and nothing else.
    private func probe(dirs: Set<String> = [], files: Set<String> = [],
                       archives: Set<String> = []) -> FileSystemProbe {
        FileSystemProbe(
            isDirectory: { dirs.contains($0) },
            isFile: { files.contains($0) },
            directoryNames: { parent in
                dirs.compactMap { d in
                    guard d.hasPrefix(parent + "/") else { return nil }
                    let rest = d.dropFirst(parent.count + 1)
                    return rest.contains("/") ? nil : String(rest)
                }
            },
            isStaticArchive: { archives.contains($0) }
        )
    }

    /// A complete, usable distribution.
    private var goodDist: FileSystemProbe {
        probe(
            dirs: ["/d", "/d/lib", "/d/lib/python3.12",
                   "/d/lib/python3.12/encodings"],
            files: ["/d/lib/libpython3.12.a"],
            archives: ["/d/lib/libpython3.12.a"])
    }

    @Test func findsACompleteDistribution() {
        let located = StaticPythonDistribution.inspect(root: "/d",
                                                       fileSystem: goodDist)
        guard case .found(let dist) = located else {
            Issue.record("expected found, got \(located)"); return
        }
        #expect(dist.version == "3.12")
        #expect(dist.archivePath == "/d/lib/libpython3.12.a")
        #expect(dist.stdlibPath == "/d/lib/python3.12")
    }

    // MARK: - The trap this whole file exists for

    @Test func aDynamicLibraryNamedDotAIsRejected() {
        // Every python.org framework install ships
        // `config-3.12-darwin/libpython3.12.a` as a symlink to the
        // framework dylib. Accepting it would produce a binary with a
        // hard dependency on /Library/Frameworks — which is exactly the
        // failure embedding is meant to prevent, wearing a static name.
        let fs = probe(
            dirs: ["/d", "/d/lib", "/d/lib/python3.12",
                   "/d/lib/python3.12/encodings"],
            files: ["/d/lib/libpython3.12.a"],
            archives: [])          // present, but not a real archive
        let located = StaticPythonDistribution.inspect(root: "/d", fileSystem: fs)
        guard case .rejected(.archiveIsDynamic(let path)) = located else {
            Issue.record("expected archiveIsDynamic, got \(located)"); return
        }
        #expect(path == "/d/lib/libpython3.12.a")
        // And the message has to explain why, or the reader will think
        // the file is missing when they can plainly see it.
        #expect("\(located)".contains("shared library")
                || StaticPythonDistribution.Rejection
                    .archiveIsDynamic(path: path).description
                    .contains("shared library"))
    }

    @Test func theArchiveMagicIsWhatDecidesIt() throws {
        // `ar` writes "!<arch>\n"; a Mach-O or ELF shared object does
        // not. Eight bytes settle a question `file` would shell out for.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let real = dir.appendingPathComponent("real.a")
        try Data("!<arch>\n/ some archive body".utf8).write(to: real)
        #expect(StaticArchiveCheck.isStaticArchive(atPath: real.path))

        let fake = dir.appendingPathComponent("fake.a")
        // Mach-O 64-bit magic, which is what the symlink resolves to.
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1]).write(to: fake)
        #expect(!StaticArchiveCheck.isStaticArchive(atPath: fake.path))

        #expect(!StaticArchiveCheck.isStaticArchive(
            atPath: dir.appendingPathComponent("absent.a").path))
    }

    // MARK: - Incomplete distributions

    @Test func anArchiveWithoutAStdlibIsRefused() {
        let fs = probe(dirs: ["/d", "/d/lib", "/d/lib/python3.12"],
                       files: ["/d/lib/libpython3.12.a"],
                       archives: ["/d/lib/libpython3.12.a"])
        // The version is readable and the archive is real, but there is
        // no `encodings` — Py_Initialize would fail at startup with a
        // message naming none of this.
        guard case .rejected(.stdlibIncomplete(_, let missing)) =
                StaticPythonDistribution.inspect(root: "/d", fileSystem: fs)
        else { Issue.record("expected stdlibIncomplete"); return }
        #expect(missing == "encodings")
    }

    @Test func noArchiveAtAllIsReportedAsSuch() {
        let fs = probe(dirs: ["/d", "/d/lib", "/d/lib/python3.12",
                              "/d/lib/python3.12/encodings"])
        guard case .rejected(.noArchive) =
                StaticPythonDistribution.inspect(root: "/d", fileSystem: fs)
        else { Issue.record("expected noArchive"); return }
    }

    @Test func aPathThatIsNotADirectoryIsReportedPlainly() {
        guard case .rejected(.notADirectory) = StaticPythonDistribution
            .inspect(root: "/nope", fileSystem: probe())
        else { Issue.record("expected notADirectory"); return }
    }

    @Test func aDistributionWithNoVersionedLibDirIsRefused() {
        let fs = probe(dirs: ["/d", "/d/lib", "/d/lib/python3"])
        // `python3` is the unversioned symlink and says nothing about
        // the minor version, which the archive name depends on.
        guard case .rejected(.versionUnreadable) =
                StaticPythonDistribution.inspect(root: "/d", fileSystem: fs)
        else { Issue.record("expected versionUnreadable"); return }
    }

    // MARK: - Layout and version selection

    @Test func theConfigDirectoryLayoutIsFound() {
        // What CPython's own `make install` produces.
        let path = "/d/lib/python3.12/config-3.12-darwin/libpython3.12.a"
        let fs = probe(
            dirs: ["/d", "/d/lib", "/d/lib/python3.12",
                   "/d/lib/python3.12/encodings",
                   "/d/lib/python3.12/config-3.12-darwin"],
            files: [path], archives: [path])
        guard case .found(let dist) =
                StaticPythonDistribution.inspect(root: "/d", fileSystem: fs)
        else { Issue.record("expected found"); return }
        #expect(dist.archivePath == path)
    }

    @Test func theHighestVersionWinsWhenThereAreTwo() {
        let fs = probe(
            dirs: ["/d", "/d/lib", "/d/lib/python3.9", "/d/lib/python3.12",
                   "/d/lib/python3.12/encodings"],
            files: ["/d/lib/libpython3.12.a"],
            archives: ["/d/lib/libpython3.12.a"])
        guard case .found(let dist) =
                StaticPythonDistribution.inspect(root: "/d", fileSystem: fs)
        else { Issue.record("expected found"); return }
        // Lexically "3.9" > "3.12"; numerically it is not.
        #expect(dist.version == "3.12")
    }

    @Test func versionsCompareNumericallyNotLexically() {
        #expect(StaticPythonDistribution.compareVersions("3.9", "3.12")
                == .orderedAscending)
        #expect(StaticPythonDistribution.compareVersions("3.12", "3.12")
                == .orderedSame)
        #expect(StaticPythonDistribution.compareVersions("3.13", "3.12")
                == .orderedDescending)
    }

    // MARK: - Locating

    @Test func nothingNamedMeansAbsentRatherThanAnError() {
        // The ordinary case on a machine that has never been asked to
        // embed Python. Not a failure, and not worth a message.
        #expect(StaticPythonDistribution.locate(
            environment: [:], fileSystem: probe()) == .absent)
        #expect(StaticPythonDistribution.locate(
            environment: [StaticPythonDistribution.environmentVariable: ""],
            fileSystem: probe()) == .absent)
    }

    @Test func theEnvironmentVariableIsHonoured() {
        let located = StaticPythonDistribution.locate(
            environment: [StaticPythonDistribution.environmentVariable: "/d"],
            fileSystem: goodDist)
        guard case .found = located else {
            Issue.record("expected found, got \(located)"); return
        }
    }

    @Test func anExplicitPathBeatsTheEnvironment() {
        // Somebody who names a path means that path.
        let located = StaticPythonDistribution.locate(
            explicitPath: "/d",
            environment: [StaticPythonDistribution.environmentVariable: "/other"],
            fileSystem: goodDist)
        guard case .found(let dist) = located else {
            Issue.record("expected found"); return
        }
        #expect(dist.root == "/d")
    }

    @Test func aNamedPathThatIsWrongIsReportedNotIgnored() {
        // Falling back silently would leave somebody staring at a
        // refusal while their ARO_STATIC_PYTHON sits there looking fine.
        let fs = probe(dirs: ["/d", "/d/lib", "/d/lib/python3.12",
                              "/d/lib/python3.12/encodings"],
                       files: ["/d/lib/libpython3.12.a"], archives: [])
        guard case .rejected = StaticPythonDistribution.locate(
            explicitPath: "/d", environment: [:], fileSystem: fs)
        else { Issue.record("expected rejected"); return }
    }
}
