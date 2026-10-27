// ============================================================
// NotebookLinkRouter.swift
// SOLARO — where a markdown link in a notebook cell goes (GitLab #899)
// ============================================================
//
// The decision was inline in `ReplNotebookView.followLink`, where it was
// reachable only by clicking a link in a running SOLARO. It was shipped that
// way and said so: "I have not clicked a link in a running SOLARO."
//
// Two different things were unverified there, and only one of them has to be.
// Whether a `Text` link tap reaches the `openURL` environment handler is
// SwiftUI's business and needs a real window. **Which destination a given URL
// resolves to** is arithmetic over paths, and needs nothing — so it lives here
// instead, as a pure function over its inputs, and the view performs the
// side effects the answer names.
//
// `fileExists` is injected for the same reason: a router that reads the real
// filesystem can only be tested against files a test has to create, which
// turns a table of twenty cases into twenty temporary directories.

import Foundation

/// Where a link in a notebook cell should be opened.
enum NotebookLinkDestination: Equatable {
    /// Let SwiftUI do what it would have done — the default browser for a web
    /// address, the system handler for anything else. Also the answer for a
    /// link that resolves to nothing, because a broken link in a notebook is
    /// not something to swallow silently.
    case systemAction
    /// A file inside the project: open it in SOLARO. This is what makes
    /// `[04](04-immutability.repl)` open the lesson rather than hand a `.repl`
    /// file to whatever the OS thinks owns that extension.
    case openInWorkspace(URL)
    /// A file outside the project: the system handler, by path.
    ///
    /// Distinct from `.systemAction` on purpose. The workspace silently drops
    /// a focus request for a file outside the project, so routing one there
    /// would eat the click; and `.systemAction` on a bare relative `file:` URL
    /// resolves against the process's working directory, not the notebook's.
    case openExternally(URL)
}

enum NotebookLinkRouter {

    /// Resolve a link.
    ///
    /// - Parameters:
    ///   - url: the link as `AttributedString(markdown:)` produced it. A
    ///     relative markdown target arrives with no scheme.
    ///   - notebookDirectory: the directory holding the notebook. A path in a
    ///     notebook is relative to the notebook, not to the process.
    ///   - projectRoot: the open project's root.
    ///   - fileExists: injected for testability; defaults to the filesystem.
    static func destination(
        for url: URL,
        notebookDirectory: URL,
        projectRoot: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> NotebookLinkDestination {
        // Anything with a scheme that is not `file:` belongs to the system:
        // https, mailto, and whatever else somebody writes. Kept rather than
        // reimplemented — SwiftUI already opens a web link correctly, and the
        // bug was that nothing was handling `openURL` at all.
        if let scheme = url.scheme?.lowercased(), scheme != "file" {
            return .systemAction
        }

        guard let target = resolve(url, relativeTo: notebookDirectory, fileExists: fileExists)
        else { return .systemAction }

        let root = projectRoot.standardizedFileURL.path
        if isInside(target.path, root: root) {
            return .openInWorkspace(target)
        }
        return .openExternally(target)
    }

    /// A link's target as an existing file, or nil.
    ///
    /// Markdown percent-encodes a path containing spaces, so the encoding is
    /// undone before the filesystem sees it.
    static func resolve(
        _ url: URL,
        relativeTo notebookDirectory: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        let raw = url.isFileURL ? url.path : url.relativePath
        let path = raw.removingPercentEncoding ?? raw
        guard !path.isEmpty else { return nil }

        // `isDirectory: true` is not decoration. `URL(fileURLWithPath:)` with
        // no trailing slash and no hint is a FILE, and resolving a relative
        // path against a file resolves against its parent — so a base of
        // `/project/Learning` turned `04-immutability.repl` into
        // `/project/04-immutability.repl`, one directory too high.
        //
        // The view's own call survives that by accident: `deletingLastPathComponent()`
        // returns a URL that already carries the trailing slash. Any other
        // caller would have been silently wrong, which is the kind of thing
        // that is only ever found by someone clicking a link.
        let base = URL(fileURLWithPath: notebookDirectory.path, isDirectory: true)
        let candidate = url.isFileURL
            ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: path, relativeTo: base)

        // Rebuilt from the path rather than returned as-is: a URL made with
        // `relativeTo:` keeps its base, and two URLs with the same path but
        // different bases are not equal. The caller gets an address, not an
        // address plus the history of how it was worked out.
        let resolved = URL(fileURLWithPath: candidate.standardizedFileURL.path)
        return fileExists(resolved.path) ? resolved : nil
    }

    /// Whether `path` is the project root or sits under it.
    ///
    /// Compared component-wise rather than with `hasPrefix`, which answers yes
    /// for `/Projects/ARO-Lang-scratch` against a root of `/Projects/ARO-Lang`
    /// — a sibling directory, routed into the workspace, where the focus
    /// request is then dropped and the click does nothing at all.
    static func isInside(_ path: String, root: String) -> Bool {
        if path == root { return true }
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
