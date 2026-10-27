// ============================================================
// NotebookLinkRouterTests.swift
// SOLARO — where a notebook link goes (GitLab #899, for the #657 handler)
// ============================================================
//
// The link handler shipped unverified: the merge request said so, because
// clicking a link needs a running SOLARO. Two things were unverified there and
// only one of them has to be. Whether a `Text` link tap reaches the `openURL`
// environment handler is SwiftUI's, and still needs a window. WHICH
// destination a URL resolves to is arithmetic over paths, and is this.
//
// The cases below are the real shapes in `Learning/`: 190 links to other
// notebooks, 281 into `Proposals/` and `Book/`, 44 web.

import Testing
import Foundation
@testable import SOLARO

@Suite("Where a notebook link goes (#899)")
struct NotebookLinkRouterTests {

    private let notebookDir = URL(fileURLWithPath: "/project/Learning")
    private let projectRoot = URL(fileURLWithPath: "/project")

    /// A filesystem where exactly these paths exist.
    private func existing(_ paths: String...) -> (String) -> Bool {
        let set = Set(paths)
        return { set.contains($0) }
    }

    private func route(_ link: String,
                       exists: @escaping (String) -> Bool) -> NotebookLinkDestination {
        NotebookLinkRouter.destination(
            for: URL(string: link)!,
            notebookDirectory: notebookDir,
            projectRoot: projectRoot,
            fileExists: exists)
    }

    // MARK: - Web

    @Test("A web address is left to the system")
    func webGoesToSystem() {
        // SwiftUI already opens these correctly. The bug was that nothing was
        // handling `openURL` at all, not that the browser was wrong.
        for link in ["https://aro-lang.org", "http://example.com/x",
                     "mailto:someone@example.com"] {
            #expect(route(link, exists: existing()) == .systemAction, "\(link)")
        }
    }

    // MARK: - Inside the project

    @Test("A sibling notebook opens in SOLARO")
    func siblingNotebookOpensInApp() {
        // `[04](04-immutability.repl)` — the commonest link in the course, and
        // the one that must NOT be handed to whatever owns the .repl extension.
        let target = "/project/Learning/04-immutability.repl"
        #expect(route("04-immutability.repl", exists: existing(target))
                == .openInWorkspace(URL(fileURLWithPath: target)))
    }

    @Test("A path up and across the project resolves against the notebook")
    func proposalLinkResolvesRelativeToNotebook() {
        // `../Proposals/ARO-0088-concurrency-model.md`. Relative to the
        // NOTEBOOK, not to the process's working directory — which is the
        // difference between opening the proposal and opening nothing.
        let target = "/project/Proposals/ARO-0088-concurrency-model.md"
        #expect(route("../Proposals/ARO-0088-concurrency-model.md", exists: existing(target))
                == .openInWorkspace(URL(fileURLWithPath: target)))
    }

    @Test("A percent-encoded path is decoded before the filesystem sees it")
    func percentEncodedPath() {
        // Markdown encodes a space. Without decoding, the file is never found
        // and the link falls through to the system, which opens nothing.
        let target = "/project/Book/The Language Guide.md"
        #expect(route("../Book/The%20Language%20Guide.md", exists: existing(target))
                == .openInWorkspace(URL(fileURLWithPath: target)))
    }

    @Test("The project root itself is inside the project")
    func rootIsInside() {
        #expect(NotebookLinkRouter.isInside("/project", root: "/project"))
        #expect(NotebookLinkRouter.isInside("/project/a/b.md", root: "/project"))
    }

    @Test("A sibling directory with the same prefix is NOT inside the project")
    func siblingDirectoryIsNotInside() {
        // The failure a bare `hasPrefix` gives: `/project-scratch` starts with
        // `/project`, so it would be routed into the workspace, where the
        // focus request is dropped — and the click does nothing at all. Worse
        // than not handling it, because the user gets no system handler either.
        #expect(!NotebookLinkRouter.isInside("/project-scratch/main.aro", root: "/project"))
        #expect(!NotebookLinkRouter.isInside("/projectile/x.md", root: "/project"))
    }

    @Test("A file outside the project goes to the system handler, by path")
    func outsideProjectOpensExternally() {
        // Distinct from `.systemAction`: the workspace would drop this one,
        // and `.systemAction` on a relative file URL resolves against the
        // process's directory rather than the notebook's.
        let target = "/elsewhere/notes.md"
        #expect(route("../../elsewhere/notes.md", exists: existing(target))
                == .openExternally(URL(fileURLWithPath: target)))
    }

    // MARK: - Nothing there

    @Test("A link to a file that does not exist falls through")
    func deadLinkFallsThrough() {
        // A broken cross-reference in the course is a thing to see, not to
        // swallow. `.systemAction` is what SwiftUI would have done.
        #expect(route("99-does-not-exist.repl", exists: existing()) == .systemAction)
    }

    @Test("An anchor-only link is not a file")
    func anchorOnlyLinkIsNotAFile() {
        // `[the rule](#streams-dont-have-a-size)` — a link into the same
        // document. Its relative path is empty, so there is no file to find;
        // resolving one would otherwise hand the notebook's own directory to
        // `fileExists`, which says yes, and the click would "open" a folder.
        let anchor = URL(string: "#streams-dont-have-a-size")!
        #expect(NotebookLinkRouter.resolve(anchor,
                                           relativeTo: notebookDir,
                                           fileExists: { _ in true }) == nil)
        #expect(route("#streams-dont-have-a-size", exists: { _ in true }) == .systemAction)
    }

    // MARK: - Absolute file URLs

    @Test("An absolute file URL is taken as given")
    func absoluteFileURL() {
        let target = "/project/Proposals/ARO-0001-language-fundamentals.md"
        let destination = NotebookLinkRouter.destination(
            for: URL(fileURLWithPath: target),
            notebookDirectory: notebookDir,
            projectRoot: projectRoot,
            fileExists: existing(target))
        #expect(destination == .openInWorkspace(URL(fileURLWithPath: target)))
    }

    @Test("A notebook directory given without a trailing slash still resolves")
    func baseDirectoryNeedNotBeMarkedAsOne() {
        // `URL(fileURLWithPath:)` with no trailing slash is a FILE, and a
        // relative path resolved against a file resolves against its PARENT:
        // `/project/Learning` + `04-immutability.repl` came out as
        // `/project/04-immutability.repl`, one directory too high.
        //
        // The view survives that by accident — `deletingLastPathComponent()`
        // returns a URL that already carries the slash — so the router
        // normalises its own input rather than depending on how it was called.
        let target = "/project/Learning/04-immutability.repl"
        for base in [URL(fileURLWithPath: "/project/Learning"),
                     URL(fileURLWithPath: "/project/Learning", isDirectory: true),
                     URL(fileURLWithPath: "/project/Learning/")] {
            let destination = NotebookLinkRouter.destination(
                for: URL(string: "04-immutability.repl")!,
                notebookDirectory: base,
                projectRoot: projectRoot,
                fileExists: existing(target))
            #expect(destination == .openInWorkspace(URL(fileURLWithPath: target)),
                    "base \(base.path) resolved wrongly")
        }
    }

    @Test("A path with .. in the middle is standardised before comparison")
    func standardisesBeforeComparing() {
        // Without standardising, `/project/Learning/../Proposals/x.md` does not
        // start with the root by string comparison in some spellings, and the
        // file handed to the workspace is a path nobody can open twice.
        let target = "/project/Proposals/x.md"
        let destination = route("../Proposals/x.md", exists: existing(target))
        guard case .openInWorkspace(let url) = destination else {
            Issue.record("expected the project route, got \(destination)")
            return
        }
        #expect(url.path == target, "the path must be standardised, not literal")
    }
}
