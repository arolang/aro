// ============================================================
// StaticPythonDistribution.swift
// AROCompiler — a CPython that can go inside the binary (#856)
// ============================================================
//
// `aro build --static` promises one file you can copy. A Python plugin
// breaks that promise three times over: the binary needs an
// interpreter, a `libpython`, and the standard library, and all three
// are resolved from the machine that ran the build.
//
// `PythonLibraryFinder` already prefers a static archive on Linux when
// one happens to exist, which addresses the second of those and neither
// of the others — the stdlib path it records is a directory on the
// build machine, so the binary is still not self-contained.
//
// This type is about the whole problem: find a CPython distribution
// that can actually be *embedded*, and say precisely why not when it
// cannot. Embedding then means linking its static archive and carrying
// its standard library inside the executable.
//
// ## The trap this file exists to avoid
//
// A python.org framework install ships a file called `libpython3.12.a`
// — and it is a symlink to the framework's dynamic library:
//
//     $ file .../config-3.12-darwin/libpython3.12.a
//     Mach-O universal binary … dynamically linked shared library
//     $ ls -l .../libpython3.12.a
//     -> ../../../Python
//
// Linking it yields a binary with a hard dependency on
// `/Library/Frameworks/Python.framework`, which looks like success and
// is the exact failure this feature is meant to prevent. So a candidate
// archive is checked for what it *is*, not for what it is named.

import Foundation

/// A CPython installation that can be linked into a standalone binary.
public struct StaticPythonDistribution: Equatable, Sendable {

    /// Where the build should look, in order, when nothing is named.
    ///
    /// Deliberately short. A distribution that can be embedded is not
    /// something a machine has by accident — it is downloaded on
    /// purpose (python-build-standalone) or built on purpose
    /// (`./configure --disable-shared`), so guessing widely would only
    /// produce more ways to pick the wrong one.
    public static let environmentVariable = "ARO_STATIC_PYTHON"

    /// Absolute path to the static archive, e.g. `…/libpython3.12.a`.
    public let archivePath: String
    /// Directory holding the standard library, e.g. `…/lib/python3.12`.
    public let stdlibPath: String
    /// `3.12`, say.
    public let version: String
    /// Root of the distribution, for diagnostics.
    public let root: String

    public init(archivePath: String, stdlibPath: String,
                version: String, root: String) {
        self.archivePath = archivePath
        self.stdlibPath = stdlibPath
        self.version = version
        self.root = root
    }

    /// What to hand the linker to fold this interpreter into the binary.
    ///
    /// The archive goes in by path rather than as `-lpython3.12`, so the
    /// linker cannot wander off and find a dynamic library of the same
    /// name somewhere else in its search path — which is precisely the
    /// accident this whole feature exists to prevent. The rest are the
    /// system libraries CPython itself needs; they are present on every
    /// target we build for, and none of them drags Python along.
    public var linkerFlags: [String] {
        #if os(macOS)
        return [archivePath, "-lm", "-lz",
                "-framework", "CoreFoundation",
                "-framework", "SystemConfiguration"]
        #else
        return [archivePath, "-ldl", "-lm", "-lutil", "-lpthread"]
        #endif
    }

    // MARK: - Why a candidate was rejected

    /// Why a directory is not a usable distribution.
    ///
    /// Each case carries what was looked for, because the person
    /// reading it is assembling a distribution and needs to know which
    /// piece is missing rather than that "it didn't work".
    public enum Rejection: Equatable, Sendable, CustomStringConvertible {
        case notADirectory(String)
        case noArchive(searchedRoot: String, version: String?)
        /// The decisive one: a file named `libpython*.a` that is really
        /// a shared library, which every python.org install ships.
        case archiveIsDynamic(path: String)
        case noStdlib(searchedRoot: String, version: String)
        /// A stdlib directory with no `encodings`, which
        /// `Py_Initialize` needs before it can do anything at all.
        case stdlibIncomplete(path: String, missing: String)
        case versionUnreadable(root: String)

        public var description: String {
            switch self {
            case .notADirectory(let p):
                return "\(p) is not a directory."
            case .noArchive(let root, let version):
                let what = version.map { "libpython\($0).a" } ?? "libpython*.a"
                return "No \(what) under \(root). A distribution that can be "
                    + "embedded ships a static archive; most do not."
            case .archiveIsDynamic(let p):
                return "\(p) is named like a static archive but is a shared "
                    + "library. Linking it would produce a binary that still "
                    + "depends on this machine's Python — which is the failure "
                    + "this check exists to prevent."
            case .noStdlib(let root, let version):
                return "No standard library at \(root)/lib/python\(version). "
                    + "The archive alone cannot start an interpreter."
            case .stdlibIncomplete(let p, let missing):
                return "The standard library at \(p) has no \(missing), which "
                    + "Py_Initialize needs before it can run anything."
            case .versionUnreadable(let root):
                return "Could not tell which Python version \(root) holds."
            }
        }
    }

    public enum Location: Equatable, Sendable {
        case found(StaticPythonDistribution)
        case rejected(Rejection)
        /// Nothing was named and nothing was found — the ordinary case
        /// on a machine that has never been asked to embed Python.
        case absent
    }

    // MARK: - Locating

    /// Find a distribution, or say why the candidate cannot be used.
    ///
    /// - Parameters:
    ///   - explicitPath: an operator's choice, normally from
    ///     `ARO_STATIC_PYTHON`. When given, it is the only place looked
    ///     at, and a problem with it is reported rather than silently
    ///     falling back — somebody who names a path wants that path.
    ///   - fileSystem: injected so the rules can be tested against
    ///     fixtures rather than against whatever this machine has.
    public static func locate(
        explicitPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileSystem: FileSystemProbe = .real
    ) -> Location {
        let named = explicitPath ?? environment[environmentVariable]
        guard let named, !named.isEmpty else { return .absent }
        return inspect(root: named, fileSystem: fileSystem)
    }

    /// Validate one candidate root.
    public static func inspect(root: String,
                               fileSystem: FileSystemProbe = .real) -> Location {
        guard fileSystem.isDirectory(root) else {
            return .rejected(.notADirectory(root))
        }
        guard let version = detectVersion(root: root, fileSystem: fileSystem) else {
            return .rejected(.versionUnreadable(root: root))
        }

        guard let archive = findArchive(root: root, version: version,
                                        fileSystem: fileSystem) else {
            return .rejected(.noArchive(searchedRoot: root, version: version))
        }
        // The whole point: a name is not evidence.
        guard fileSystem.isStaticArchive(archive) else {
            return .rejected(.archiveIsDynamic(path: archive))
        }

        let stdlib = "\(root)/lib/python\(version)"
        guard fileSystem.isDirectory(stdlib) else {
            return .rejected(.noStdlib(searchedRoot: root, version: version))
        }
        // `encodings` is the module Py_Initialize reaches for first; a
        // stdlib without it fails at startup with an error that names
        // none of this.
        guard fileSystem.isDirectory("\(stdlib)/encodings") else {
            return .rejected(.stdlibIncomplete(path: stdlib, missing: "encodings"))
        }

        return .found(StaticPythonDistribution(
            archivePath: archive, stdlibPath: stdlib,
            version: version, root: root))
    }

    /// The `3.12` in `lib/python3.12`.
    static func detectVersion(root: String,
                              fileSystem: FileSystemProbe) -> String? {
        fileSystem.directoryNames("\(root)/lib")
            .compactMap { name -> String? in
                guard name.hasPrefix("python") else { return nil }
                let suffix = String(name.dropFirst("python".count))
                // `python3.12` yes, `python3` no — the latter is the
                // symlink, and it tells us nothing about the minor.
                guard suffix.contains("."), suffix.allSatisfy({
                    $0.isNumber || $0 == "."
                }) else { return nil }
                return suffix
            }
            // Highest wins when a distribution carries two.
            .max { lhs, rhs in
                compareVersions(lhs, rhs) == .orderedAscending
            }
    }

    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let lhs = a.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// The two places a static archive is kept.
    static func findArchive(root: String, version: String,
                            fileSystem: FileSystemProbe) -> String? {
        let name = "libpython\(version).a"
        var candidates = ["\(root)/lib/\(name)"]
        // CPython's own `make install` puts it under a config directory
        // whose name carries the platform triple.
        for config in fileSystem.directoryNames("\(root)/lib/python\(version)")
        where config.hasPrefix("config-") {
            candidates.append("\(root)/lib/python\(version)/\(config)/\(name)")
        }
        return candidates.first { fileSystem.isFile($0) }
    }
}

// MARK: - Filesystem access, injectable

/// The filesystem questions this file asks.
///
/// A protocol-free struct of closures: there are four questions, the
/// real implementation is four lines, and a test fixture is a
/// dictionary. A protocol would be more ceremony than the thing it
/// describes.
public struct FileSystemProbe: Sendable {
    public var isDirectory: @Sendable (String) -> Bool
    public var isFile: @Sendable (String) -> Bool
    public var directoryNames: @Sendable (String) -> [String]
    /// Whether a path is a *real* static archive rather than a shared
    /// library wearing a `.a` name.
    public var isStaticArchive: @Sendable (String) -> Bool

    public init(
        isDirectory: @escaping @Sendable (String) -> Bool,
        isFile: @escaping @Sendable (String) -> Bool,
        directoryNames: @escaping @Sendable (String) -> [String],
        isStaticArchive: @escaping @Sendable (String) -> Bool
    ) {
        self.isDirectory = isDirectory
        self.isFile = isFile
        self.directoryNames = directoryNames
        self.isStaticArchive = isStaticArchive
    }

    public static let real = FileSystemProbe(
        isDirectory: { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                && isDir.boolValue
        },
        isFile: { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                && !isDir.boolValue
        },
        directoryNames: { path in
            ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
                .filter { name in
                    var isDir: ObjCBool = false
                    return FileManager.default.fileExists(
                        atPath: "\(path)/\(name)", isDirectory: &isDir)
                        && isDir.boolValue
                }
        },
        isStaticArchive: { path in
            StaticArchiveCheck.isStaticArchive(atPath: path)
        }
    )
}

/// Tells a static archive from a shared library by reading the file.
///
/// A `.a` produced by `ar` begins with the eight bytes `!<arch>\n`. A
/// Mach-O or ELF shared object does not, and neither does a symlink
/// resolved to one. Reading eight bytes is cheaper and more honest than
/// shelling out to `file`, and it works the same on both platforms.
public enum StaticArchiveCheck {
    public static let magic = Array("!<arch>\n".utf8)

    public static func isStaticArchive(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: magic.count) else {
            return false
        }
        return Array(head) == magic
    }
}
