// ============================================================
// SourceFiles.swift
// ARO CLI - Locating the .aro files under an application directory
// ============================================================
//
// `aro check` and `aro compile` each carried a byte-identical copy of this
// walk. The rule it encodes — every `.aro` file at any depth, hidden
// directories skipped, sorted by path so the report is stable between runs —
// is a property of what an ARO application *is*, not of either command, so
// the two copies could only ever drift apart (#732).

import Foundation

enum SourceFiles {
    /// Every `.aro` file under `directory`, at any depth, sorted by path.
    ///
    /// Hidden entries are skipped, so a `.build` directory left by a previous
    /// `aro build` does not turn its copied sources into a second application.
    /// An unreadable directory yields no files rather than an error: the
    /// caller's own "no source files" report says more than an enumerator
    /// failure would.
    static func find(in directory: URL) throws -> [URL] {
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var sourceFiles: [URL] = []

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "aro" {
                sourceFiles.append(fileURL)
            }
        }

        return sourceFiles.sorted { $0.path < $1.path }
    }
}
