// ============================================================
// PythonStdlibBundle.swift
// AROCompiler — the standard library, carried inside (#856)
// ============================================================
//
// A static `libpython` is half of a self-contained interpreter. The
// other half is the standard library: `Py_Initialize` imports
// `encodings` before it will run anything, and any real plugin reaches
// for `json`, `re` or `pathlib` immediately after.
//
// So the build carries it. Which raises the only interesting question
// here — *what* to carry. The full tree on a python.org 3.12 install is
// 1.3 GB, and almost none of that belongs in a binary:
//
//   | part                         | size    | carried |
//   |------------------------------|---------|---------|
//   | core `.py` modules           | 10.2 MB | yes     |
//   | `test/` (CPython's own)      | large   | no      |
//   | `idlelib/`, `tkinter/`       | large   | no      |
//   | `__pycache__/`               | varies  | no      |
//   | `site-packages/`             | varies  | see below |
//
// `site-packages` is excluded and the plugin's own dependencies are
// added explicitly instead. Copying whatever happens to be installed on
// the build machine is how a binary acquires dependencies nobody
// declared — the same class of mistake as resolving the interpreter
// from the build machine, which is what this feature exists to stop.
//
// The selection rules live here, separate from the copying, because
// they are the part worth testing: "does this path belong in the
// bundle" is a question with right answers, and it is answerable
// without a filesystem.

import Foundation

public enum PythonStdlibBundle {

    /// Directory names never carried into a binary.
    ///
    /// `test` is CPython's own suite, tens of megabytes of material no
    /// running program imports. `idlelib` and `tkinter` need a display
    /// and a Tcl/Tk that a headless target will not have. `__pycache__`
    /// is regenerated and its `.pyc` files are stamped with the build
    /// machine's paths.
    public static let excludedDirectories: Set<String> = [
        "test", "tests", "idlelib", "tkinter", "turtledemo",
        "__pycache__", "site-packages", "dist-packages", "lib2to3",
    ]

    /// Suffixes never carried.
    ///
    /// `.pyc` because it is regenerated and machine-stamped; `.pyo` is
    /// its older spelling. `.a` and `.o` are build leftovers some
    /// distributions ship under `config-*`.
    public static let excludedSuffixes: [String] = [".pyc", ".pyo", ".a", ".o"]

    /// Whether a path inside the stdlib belongs in the bundle.
    ///
    /// - Parameter relativePath: path relative to the stdlib root, with
    ///   `/` separators, e.g. `json/decoder.py`.
    public static func shouldInclude(relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return false }

        // An excluded directory anywhere in the path excludes what is
        // under it: `json/__pycache__/decoder.cpython-312.pyc` goes,
        // and so does everything beneath `test/`.
        for component in components.dropLast()
        where excludedDirectories.contains(component) {
            return false
        }
        // A top-level entry that is itself an excluded directory.
        if components.count == 1, excludedDirectories.contains(components[0]) {
            return false
        }
        let last = components[components.count - 1]
        for suffix in excludedSuffixes where last.hasSuffix(suffix) {
            return false
        }
        return true
    }

    /// Where a binary looks for the standard library it carries.
    ///
    /// Extracted beside the executable rather than into a temporary
    /// directory: a temp directory is cleared out from under a
    /// long-running service, and `/tmp` is often mounted `noexec`,
    /// which the stdlib's C extensions cannot survive.
    public static func runtimeDirectoryName(version: String) -> String {
        "aro-python\(version)"
    }

    /// The `PYTHONHOME` a binary sets for its carried stdlib.
    public static func pythonHome(besideExecutable executable: String,
                                  version: String) -> String {
        let dir = (executable as NSString).deletingLastPathComponent
        return "\(dir)/\(runtimeDirectoryName(version: version))"
    }

    // MARK: - Staging

    public struct StagingReport: Equatable, Sendable {
        public let fileCount: Int
        public let byteCount: Int
        public let destination: String
    }

    /// Copy the parts of `stdlibPath` that belong in a binary into
    /// `destination`.
    ///
    /// Returns what was carried, because size is the thing anyone
    /// reviewing this feature will want to know — it is the cost of
    /// embedding Python, and it belongs in the build's output rather
    /// than in a surprise at the end.
    @discardableResult
    public static func stage(stdlibPath: String,
                             into destination: String,
                             fileManager: FileManager = .default) throws -> StagingReport {
        // Resolved, because on macOS `/tmp` is a symlink to
        // `/private/tmp`: the enumerator yields resolved paths while a
        // caller-supplied root is usually not, so a plain prefix
        // comparison fails and every file lands flat in the
        // destination. A test caught exactly that.
        let root = URL(fileURLWithPath: stdlibPath).resolvingSymlinksInPath()
        let out = URL(fileURLWithPath: destination)
        try fileManager.createDirectory(at: out, withIntermediateDirectories: true)

        var files = 0
        var bytes = 0
        guard let walker = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else {
            return StagingReport(fileCount: 0, byteCount: 0, destination: destination)
        }

        for case let item as URL in walker {
            let resolved = item.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(root.path + "/") else { continue }
            let relative = String(resolved.dropFirst(root.path.count + 1))
            guard shouldInclude(relativePath: relative) else {
                // Skipping the directory itself skips its whole subtree,
                // which is the difference between minutes and hours on
                // a 1.3 GB source tree.
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: item.path, isDirectory: &isDir),
                   isDir.boolValue {
                    walker.skipDescendants()
                }
                continue
            }
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDir),
                  !isDir.boolValue else { continue }

            let target = out.appendingPathComponent(relative)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: item, to: target)
            files += 1
            bytes += (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return StagingReport(fileCount: files, byteCount: bytes,
                             destination: destination)
    }
}
