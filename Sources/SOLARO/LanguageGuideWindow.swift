// ============================================================
// LanguageGuideWindow.swift
// SOLARO — bundled in-app Language Guide viewer (#279)
// ============================================================
//
// MVP: opens a standalone NSWindow hosting a SwiftUI sidebar +
// detail view. The sidebar lists chapters; the detail area
// renders the chapter's markdown via AttributedString so links
// and emphasis come through. Content is shipped inline in this
// file so the window works without bundle resources — richer
// bundled docs can grow on top via `LanguageGuide.fromBundle()`
// when Package.swift declares Book/ as a resource.

import SwiftUI
import AppKit

struct LanguageGuideChapter: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let summary: String
    let markdown: String
}

enum LanguageGuide {
    static let chapters: [LanguageGuideChapter] = [
        .init(
            title: "Overview",
            summary: "What ARO is and why the grammar is shaped this way.",
            markdown: """
            **ARO** stands for *Action-Result-Object*. Every statement
            names an action, the result it produces, and the object
            it acts on. The grammar is rigid by design so it round-
            trips losslessly between text and the canvas.

            Reach for ARO when you want a workflow that's both
            human-readable and reviewable as a diagram. Reach for a
            general-purpose language when you need algorithms.
            """
        ),
        .init(
            title: "Feature Sets",
            summary: "The unit of organisation; how an application is built.",
            markdown: """
            Every `.aro` file contains one or more **feature sets**.
            A feature set bundles statements that respond to a
            specific event — an HTTP route, a custom domain event,
            a repository observer, a file watcher.

            ```aro
            (createUser: User API) {
                Extract the <data> from the <request: body>.
                Create the <user> with <data>.
                Emit a <UserCreated: event> with <user>.
                Return a <Created: status> with <user>.
            }
            ```

            The business activity (`User API` above) decides which
            event triggers the feature set. `operationId`-shaped
            names match an OpenAPI route; `XYZ Handler` matches
            custom events; `<repo> Observer` matches store changes.
            """
        ),
        .init(
            title: "Actions",
            summary: "Verbs, semantic roles, and how to extend the registry.",
            markdown: """
            Actions are classified by data-flow direction:

            * **REQUEST** — `Extract`, `Parse`, `Retrieve`, `Fetch`,
              `Pull`, `Clone`. Data flows from outside the program
              into a binding.
            * **OWN** — `Compute`, `Validate`, `Compare`, `Create`,
              `Transform`, `Stage`, `Checkout`. Internal-to-internal.
            * **RESPONSE** — `Return`, `Throw`. Data flows back out.
            * **EXPORT** — `Publish`, `Store`, `Log`, `Send`, `Emit`,
              `Commit`, `Push`, `Tag`. Side effects on the outside
              world.

            Plugins extend the registry. See **Plugin System** for
            the SDKs (Swift, Rust, C, Python).
            """
        ),
        .init(
            title: "Events",
            summary: "How feature sets talk to each other.",
            markdown: """
            Feature sets don't call each other directly. They emit
            events, and other feature sets subscribe by naming the
            event in their header.

            ```aro
            (Send Welcome Email: UserCreated Handler) {
                Extract the <user> from the <event: user>.
                Send the <welcome-email> to the <user: email>.
                Return an <OK: status> for the <notification>.
            }
            ```

            The runtime's event bus dispatches in declaration order.
            Repository changes (`store`, `update`, `delete`) emit
            built-in events. File and socket events do too.
            """
        ),
        .init(
            title: "Contract-First HTTP",
            summary: "Why openapi.yaml is required for the server.",
            markdown: """
            ARO is **contract-first**. The HTTP server reads
            `openapi.yaml` at boot. Routes are matched to feature
            sets by `operationId`.

            * **Without** `openapi.yaml` — no HTTP server starts.
            * **With** `openapi.yaml` — every route declared there
              must have a feature set; the compiler complains if
              one is missing.

            This means the contract and the implementation can't
            drift: the compiler links them by name.
            """
        ),
        .init(
            title: "Resources",
            summary: "Where to learn more.",
            markdown: """
            * Proposals live in `Proposals/` — the authoritative
              language spec, ordered by ARO-NNNN.
            * The Book (long-form guide) lives in `Book/`.
            * The wiki at github.com/arolang/aro/wiki tracks
              the rendered docs.
            * `aro actions` lists every registered verb in your
              project, including plugin extensions.
            * `aro ask` opens a local AI assistant grounded in the
              current project.
            """
        )
    ]
}

@MainActor
final class LanguageGuideWindow {
    private static var window: NSWindow?

    static func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let view = LanguageGuideView()
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.setContentSize(NSSize(width: 860, height: 600))
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = "ARO Language Guide"
        w.center()
        w.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { _ in
            LanguageGuideWindow.window = nil
        }
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

struct LanguageGuideView: View {
    @State private var selection: LanguageGuideChapter.ID? = LanguageGuide.chapters.first?.id

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(LanguageGuide.chapters) { chapter in
                    NavigationLink(value: chapter.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chapter.title)
                                .font(SolaroFont.bodyBold)
                            Text(chapter.summary)
                                .font(SolaroFont.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            .listStyle(.sidebar)
        } detail: {
            ScrollView {
                if let chapter = LanguageGuide.chapters.first(where: { $0.id == selection }) {
                    VStack(alignment: .leading, spacing: SolaroSpace.m) {
                        Text(chapter.title)
                            .font(.system(size: 28, weight: .semibold))
                        Text(chapter.summary)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Divider()
                        if let attributed = try? AttributedString(
                            markdown: chapter.markdown,
                            options: .init(
                                interpretedSyntax: .inlineOnlyPreservingWhitespace
                            )
                        ) {
                            Text(attributed)
                                .font(.body)
                                .textSelection(.enabled)
                        } else {
                            Text(chapter.markdown)
                                .font(SolaroFont.mono)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(SolaroSpace.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Pick a chapter on the left.")
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
        }
    }
}
