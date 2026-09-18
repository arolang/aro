// ============================================================
// LearningNotebooks.swift
// SOLARO — the Learning course, offered on first run
// ============================================================
//
// `Learning/` upstream is a course of runnable `.repl` notebooks
// (ARO-0091): markdown prose between live ARO cells, executed
// against a real REPL session. It is the shortest path from
// "SOLARO is installed" to "I can read and write ARO", and until
// now nothing in the app told a new user it existed.
//
// So: on a genuinely first launch the welcome screen offers to
// install it. Say yes and we mirror `Learning/` out of GitHub
// into ~/Documents/ARO Learning and open it as a project, with
// the first notebook focused. Say no and we remember that and
// never ask again — the offer stays reachable from the welcome
// screen's third tile and from Help → Learning Notebooks…
//
// The download follows `Books.swift`: GitHub's Contents API (no
// `git` dependency), staged into a temp directory, swapped into
// place with two renames so a failure halfway leaves whatever was
// there before intact. The one difference is the ref: a book
// tracks `main`, but the course teaches the language *this build*
// speaks, so it pins to the release tag matching `AROVersion`.

import SwiftUI
import AppKit
import Foundation
import AROVersion

// MARK: - Pure pieces

/// Naming, URL construction and on-disk layout for the course.
/// Everything here is a pure function of its inputs so the paths
/// that decide *what* gets downloaded and *where* it lands are
/// testable without touching the network.
enum LearningCourse {

    /// Upstream repository the course is mirrored from.
    static let repositorySlug = "arolang/aro"

    /// Directory inside that repository.
    static let remoteDirectory = "Learning"

    /// Directory name created in the user's Documents folder.
    static let folderName = "ARO Learning"

    /// The notebook the course opens on.
    static let openingNotebook = "01-hello-aro.repl"

    /// Fallback ref for builds that carry no release tag — a local
    /// `swift build` reports the `dev` sentinel, and there is no
    /// `dev` tag to fetch.
    static let fallbackRef = "main"

    /// The release tag matching a running version, or `nil` when
    /// this build isn't a release.
    ///
    /// Upstream tags are bare dotted versions (`0.11.2`), with a
    /// `v`-prefixed spelling surviving from the beta era, so a
    /// leading `v` is dropped. `dev`, `unknown` and any `-dirty`
    /// build has no tag on GitHub at all — those return nil rather
    /// than sending the user at a 404.
    static func releaseTag(forVersion version: String) -> String? {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        guard !text.isEmpty,
              !text.contains("dirty"),
              // `SolaroVersion.components` returns [] unless the
              // leading component is numeric — the same test that
              // keeps the update checker from nagging dev builds.
              !SolaroVersion.components(text).isEmpty
        else { return nil }
        return text
    }

    /// The git ref the download should use for a running version.
    static func ref(forVersion version: String) -> String {
        releaseTag(forVersion: version) ?? fallbackRef
    }

    /// True when `ref` is the un-pinned fallback rather than a
    /// release tag — the UI says so, because course and runtime
    /// can then disagree.
    static func isFallbackRef(_ ref: String) -> Bool { ref == fallbackRef }

    /// GitHub Contents API listing for one directory at one ref.
    static func listingURL(ref: String, path: String = remoteDirectory) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(repositorySlug)/contents/\(path)"
        components.queryItems = [URLQueryItem(name: "ref", value: ref)]
        // Force-unwrap: host and path come from literals and from
        // repository paths that are already URL-safe, and the ref
        // goes through query-item encoding. Same call shape as
        // `SolaroUpdate.feedURL` — a typo here fails on first use.
        return components.url!
    }

    /// Strip the `Learning/` prefix off a repository path so the
    /// local mirror is rooted at the course, not at the repo.
    /// Paths that don't carry the prefix come back unchanged.
    static func relativePath(fromRepositoryPath path: String) -> String {
        let prefix = remoteDirectory + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }

    /// Where the course is installed. Documents is the honest
    /// place for it: this is the user's copy, they will edit the
    /// notebooks as they work through them, and Application
    /// Support is where things the user isn't meant to open live.
    /// Application Support is only the fallback for the case where
    /// there is no Documents directory at all.
    static func destinationDirectory(
        documentsDirectory: URL?,
        applicationSupportDirectory: URL?
    ) -> URL {
        if let documentsDirectory {
            return documentsDirectory.appendingPathComponent(folderName)
        }
        if let applicationSupportDirectory {
            return applicationSupportDirectory
                .appendingPathComponent("SOLARO")
                .appendingPathComponent(folderName)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents")
            .appendingPathComponent(folderName)
    }

    /// The resolved install directory for this user.
    static var installDirectory: URL {
        let manager = FileManager.default
        return destinationDirectory(
            documentsDirectory: manager
                .urls(for: .documentDirectory, in: .userDomainMask).first,
            applicationSupportDirectory: manager
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
    }

    /// Notebook filenames already sitting in `directory`, sorted so
    /// `01-…` comes first. Empty when the directory is missing.
    static func installedNotebooks(
        at directory: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        guard let names = try? fileManager
            .contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return names
            .filter { $0.hasSuffix(".\(ReplFile.fileExtension)") }
            .sorted()
    }

    /// A directory counts as an install once it holds a notebook.
    /// An empty directory the user happened to create does not —
    /// that would leave them with a permanent "already installed"
    /// state and no way to get the course.
    static func isInstalled(
        at directory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        !installedNotebooks(at: directory, fileManager: fileManager).isEmpty
    }

    /// Should the welcome screen raise the offer unasked?
    ///
    /// Only on a launch with no prior state at all: the user has
    /// never answered the question, has no recent projects, and
    /// has no copy of the course on disk. Answering it either way
    /// is what stops it coming back — declining must not turn into
    /// a prompt on every launch.
    static func shouldPromptOnLaunch(
        answered: Bool,
        hasRecentProjects: Bool,
        isInstalled: Bool
    ) -> Bool {
        !answered && !hasRecentProjects && !isInstalled
    }
}

// MARK: - Download store

/// Downloads the course and tracks what's on disk. One shared
/// instance (`LearningCourseStore.shared`) so the welcome card and
/// the Help-menu window show the same progress and the same error
/// rather than racing each other into the same directory.
@MainActor
@Observable
final class LearningCourseStore {

    static let shared = LearningCourseStore()

    enum Phase: Equatable {
        case idle
        case downloading(completed: Int, total: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// Notebook filenames currently installed. Drives `isInstalled`
    /// and the "N notebooks" line.
    private(set) var installedNotebooks: [String] = []

    /// Ref used by the last download attempt — shown so the user
    /// knows whether they got the pinned course or `main`.
    private(set) var lastRef: String?

    /// Set when a download failed in a way retrying against `main`
    /// could fix: the release tag has no `Learning/` (an older
    /// release, or a tag that never shipped the course).
    private(set) var offersFallbackRetry = false

    let destination: URL

    init(destination: URL = LearningCourse.installDirectory) {
        self.destination = destination
        refreshInstalled()
    }

    var isInstalled: Bool { !installedNotebooks.isEmpty }

    var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    /// The ref a download started right now would use.
    var pinnedRef: String {
        LearningCourse.ref(forVersion: AROVersion.shortVersion)
    }

    /// Re-read the install directory. Cheap — one directory listing.
    func refreshInstalled() {
        installedNotebooks = LearningCourse.installedNotebooks(at: destination)
    }

    /// Mirror `Learning/` into `destination`. Returns the directory
    /// on success, `nil` on any failure (with `phase` carrying the
    /// message the UI shows).
    ///
    /// `ref` defaults to the release tag matching this build; the
    /// UI passes `LearningCourse.fallbackRef` explicitly when the
    /// user takes the "try main" retry.
    @discardableResult
    func download(ref explicitRef: String? = nil) async -> URL? {
        guard !isDownloading else { return nil }
        let ref = explicitRef ?? pinnedRef
        lastRef = ref
        offersFallbackRetry = false
        phase = .downloading(completed: 0, total: 0)

        let files: [RemoteFile]
        do {
            files = try await enumerateCourse(ref: ref)
        } catch {
            phase = .failed(describe(error))
            offersFallbackRetry = isMissingRef(error)
                && !LearningCourse.isFallbackRef(ref)
            return nil
        }
        guard !files.isEmpty else {
            phase = .failed(
                "\(LearningCourse.remoteDirectory)/ is empty at \(ref) — nothing to download.")
            offersFallbackRetry = !LearningCourse.isFallbackRef(ref)
            return nil
        }

        let manager = FileManager.default
        // Stage beside the destination so the swap below is a
        // rename on the same volume, never a copy.
        let staging = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".solaro-learning-\(UUID().uuidString)")
        do {
            try manager.createDirectory(
                at: staging, withIntermediateDirectories: true)
        } catch {
            phase = .failed(
                "Couldn't create a staging directory: \(error.localizedDescription)")
            return nil
        }

        phase = .downloading(completed: 0, total: files.count)
        for (index, file) in files.enumerated() {
            do {
                let (data, response) = try await URLSession.shared
                    .data(from: file.url)
                try checkStatus(response, describing: file.relativePath)
                let target = staging.appendingPathComponent(file.relativePath)
                try manager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try data.write(to: target, options: [.atomic])
            } catch {
                // A half-downloaded course is worse than none: the
                // user would work through it and hit a missing
                // fixture five notebooks in. Throw the staging
                // directory away and say which file failed.
                try? manager.removeItem(at: staging)
                phase = .failed(
                    "Couldn't download \(file.relativePath): \(describe(error))")
                return nil
            }
            phase = .downloading(completed: index + 1, total: files.count)
        }

        // Atomic swap: existing copy out of the way, staging in,
        // backup deleted. Two renames, and a rollback if the
        // second one fails, so an update can't destroy the copy
        // the user has been working in.
        let backup = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".solaro-learning-backup-\(UUID().uuidString)")
        if manager.fileExists(atPath: destination.path) {
            try? manager.moveItem(at: destination, to: backup)
        }
        do {
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try manager.moveItem(at: staging, to: destination)
        } catch {
            if manager.fileExists(atPath: backup.path) {
                try? manager.moveItem(at: backup, to: destination)
            }
            try? manager.removeItem(at: staging)
            phase = .failed(
                "Couldn't finish installing the course: \(error.localizedDescription)")
            refreshInstalled()
            return nil
        }
        // Best-effort cleanup of the previous copy — the install
        // already succeeded, so a leftover backup directory is not
        // worth failing the download over.
        try? manager.removeItem(at: backup)

        refreshInstalled()
        phase = .idle
        return destination
    }

    // MARK: - GitHub walk

    private struct RemoteFile {
        let relativePath: String
        let url: URL
    }

    /// The fields of a Contents API entry the walk uses.
    private struct GitHubContentEntry: Decodable {
        let name: String
        let path: String
        let type: String
        let download_url: String?
    }

    private enum CourseDownloadError: Error {
        /// The ref (or `Learning/` within it) doesn't exist.
        case missingRef(String)
        case badStatus(Int, String)
        case malformedListing(String)

        var message: String {
            switch self {
            case .missingRef(let ref):
                return "github.com/\(LearningCourse.repositorySlug) has no "
                    + "\(LearningCourse.remoteDirectory)/ at \(ref)."
            case .badStatus(let code, let path):
                return "GitHub answered \(code) for \(path)."
            case .malformedListing(let path):
                return "Couldn't read GitHub's listing of \(path)."
            }
        }
    }

    /// Walk `Learning/` and every directory under it, collecting
    /// downloadable files. Hidden entries are skipped; so are
    /// symlinks and submodules, neither of which the course uses.
    private func enumerateCourse(ref: String) async throws -> [RemoteFile] {
        var pending = [LearningCourse.remoteDirectory]
        var found: [RemoteFile] = []
        while let path = pending.popLast() {
            for entry in try await listing(path: path, ref: ref) {
                if entry.name.hasPrefix(".") { continue }
                switch entry.type {
                case "dir":
                    pending.append(entry.path)
                case "file":
                    guard let raw = entry.download_url,
                          let url = URL(string: raw)
                    else { continue }
                    found.append(RemoteFile(
                        relativePath: LearningCourse
                            .relativePath(fromRepositoryPath: entry.path),
                        url: url))
                default:
                    continue
                }
            }
        }
        return found.sorted { $0.relativePath < $1.relativePath }
    }

    private func listing(
        path: String, ref: String
    ) async throws -> [GitHubContentEntry] {
        var request = URLRequest(url: LearningCourse.listingURL(ref: ref, path: path))
        request.setValue("application/vnd.github+json",
                         forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response, describing: path, ref: ref)
        do {
            return try JSONDecoder().decode([GitHubContentEntry].self, from: data)
        } catch {
            throw CourseDownloadError.malformedListing(path)
        }
    }

    /// Turn a non-2xx response into an error. A 404 on the listing
    /// is the interesting one — it means the tag (or the course
    /// inside it) isn't there, which is what the "try main" retry
    /// is for.
    private func checkStatus(
        _ response: URLResponse, describing path: String, ref: String? = nil
    ) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 404, let ref {
            throw CourseDownloadError.missingRef(ref)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CourseDownloadError.badStatus(http.statusCode, path)
        }
    }

    private func isMissingRef(_ error: Error) -> Bool {
        if case .missingRef = error as? CourseDownloadError { return true }
        return false
    }

    /// Plain-language failure text. The network cases are the ones
    /// a user can act on, so they get their own sentences instead
    /// of Foundation's.
    private func describe(_ error: Error) -> String {
        if let courseError = error as? CourseDownloadError {
            return courseError.message
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "No network connection."
            case .timedOut:
                return "The connection to github.com timed out."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Couldn't reach github.com."
            default:
                break
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Opening the course

/// Open an installed course as a SOLARO project, landing on the
/// first notebook.
///
/// `open` is how the caller routes the project: the welcome screen
/// swaps its own window over to it, the Help menu asks SwiftUI for
/// a new one.
@MainActor
func openLearningCourse(
    at directory: URL,
    open: (Project) -> Void
) {
    let project = Project(rootPath: directory)
    RecentProjects.remember(project)
    open(project)
    let notebook = directory
        .appendingPathComponent(LearningCourse.openingNotebook)
    guard FileManager.default.fileExists(atPath: notebook.path) else { return }
    // Same hand-off `RootView.openURL` uses for a double-clicked
    // file: the workspace subscribes to `.solaroFocusFile` and can
    // only honour it once the project has finished loading.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        NotificationCenter.default.post(
            name: .solaroFocusFile, object: nil,
            userInfo: ["url": notebook])
    }
}

// MARK: - The card

/// The course offer, rendered as one card. The welcome screen
/// shows it inline (with a "Not now" that answers the first-run
/// question); the Help-menu window shows the same card without
/// the dismissal.
struct LearningCourseCard: View {
    @Bindable var store: LearningCourseStore
    /// Called with the install directory once the user asks to
    /// open the course.
    let onOpen: (URL) -> Void
    /// Called when the user answers the offer either way, so the
    /// welcome screen can record that it was asked. Nil in the
    /// Help-menu window — opening that window isn't an answer to a
    /// question nobody asked.
    var onAnswered: (() -> Void)?
    /// Called when the user declines. Nil hides the button.
    var onDecline: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: SolaroSpace.m) {
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 22))
                .foregroundStyle(SolaroColor.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: SolaroSpace.s) {
                Text("Learn the ARO essentials")
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(SolaroColor.textPrimary)
                Text(blurb)
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                controls
                footnote
            }
            Spacer(minLength: 0)
        }
        .padding(SolaroSpace.m)
        .background(SolaroColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.m)
                .stroke(SolaroColor.accent.opacity(0.35), lineWidth: 1)
        )
        .frame(maxWidth: 560)
        .onAppear { store.refreshInstalled() }
    }

    private var blurb: String {
        store.isInstalled
            ? "The notebook course is installed. Work through it in SOLARO — each notebook is prose with live ARO cells you can run and edit."
            : "The notebook course is the best way to learn the ARO essentials: a guided, runnable sequence of .repl notebooks that build one café ordering system, a capability at a time."
    }

    @ViewBuilder
    private var controls: some View {
        switch store.phase {
        case .downloading(let completed, let total):
            HStack(spacing: SolaroSpace.s) {
                ProgressView().controlSize(.small)
                Text(total == 0
                     ? "Looking up the course on GitHub…"
                     : "Downloading \(completed) of \(total) files…")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textSecondary)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: SolaroSpace.xs) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.stateWarn)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: SolaroSpace.s) {
                    Button("Try again") { startDownload() }
                    if store.offersFallbackRetry {
                        Button("Use the latest course") {
                            startDownload(ref: LearningCourse.fallbackRef)
                        }
                        .help("Download Learning/ from the main branch instead of the release matching this build.")
                    }
                    if store.isInstalled {
                        Button("Open the installed copy") { onOpen(store.destination) }
                    }
                    declineButton
                }
            }

        case .idle:
            HStack(spacing: SolaroSpace.s) {
                if store.isInstalled {
                    Button("Open notebooks") {
                        onAnswered?()
                        onOpen(store.destination)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Check for updates") { startDownload() }
                        .help("Re-download the course. Your copy is replaced only once every file has arrived.")
                } else {
                    Button("Download notebooks") { startDownload() }
                        .buttonStyle(.borderedProminent)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.destination])
                }
                .disabled(!store.isInstalled)
                declineButton
            }
        }
    }

    @ViewBuilder
    private var declineButton: some View {
        if let onDecline {
            Button("Not now") {
                onAnswered?()
                onDecline()
            }
            .buttonStyle(.plain)
            .font(SolaroFont.caption)
            .foregroundStyle(SolaroColor.textTertiary)
        }
    }

    @ViewBuilder
    private var footnote: some View {
        let ref = store.lastRef ?? store.pinnedRef
        VStack(alignment: .leading, spacing: 2) {
            if store.isInstalled {
                Text("\(store.installedNotebooks.count) notebooks in \(store.destination.path)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Downloads \(LearningCourse.remoteDirectory)/ from github.com/\(LearningCourse.repositorySlug) at \(ref) into \(store.destination.path)")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if LearningCourse.isFallbackRef(ref) {
                Text("This build carries no release tag, so the course comes from \(LearningCourse.fallbackRef) and may be ahead of the runtime.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func startDownload(ref: String? = nil) {
        onAnswered?()
        Task { await store.download(ref: ref) }
    }
}

// MARK: - Help-menu window

/// Standalone window for Help → Learning Notebooks…, so someone
/// who declined on day one can still get the course on day two.
/// Same shape as `CrashLogsWindow`.
@MainActor
final class LearningCourseWindow {
    private static var window: NSWindow?

    static func show(onOpenProject: @escaping (Project) -> Void) {
        if let existing = window {
            LearningCourseStore.shared.refreshInstalled()
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: LearningCourseWindowView(
            onOpenProject: onOpenProject))
        let w = NSWindow(contentViewController: host)
        w.setContentSize(NSSize(width: 620, height: 340))
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = "Learning Notebooks"
        w.center()
        w.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { _ in
            // The observer is queued on `.main`, so the main actor's
            // executor is already the one running this — assume the
            // isolation rather than hop, which would let a reopen
            // race the teardown. (`CrashLogsWindow` does the same
            // thing without the assumption and warns for it.)
            MainActor.assumeIsolated { LearningCourseWindow.window = nil }
        }
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
        window = nil
    }
}

private struct LearningCourseWindowView: View {
    let onOpenProject: (Project) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.m) {
            LearningCourseCard(store: LearningCourseStore.shared) { directory in
                openLearningCourse(at: directory, open: onOpenProject)
                LearningCourseWindow.close()
            }
            Spacer(minLength: 0)
        }
        .padding(SolaroSpace.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Help-menu entry. A `View` rather than a bare `Button` so it can
/// hold `@Environment(\.openWindow)` — opening the course from the
/// menu bar means a fresh workspace window, the same way ⌘-clicking
/// a recent project does.
struct LearningNotebooksCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            LearningCourseWindow.show { project in
                PendingNewWindowProject.queue(project)
                openWindow(id: SolaroWindowID.workspace)
            }
        } label: {
            Label("Learning Notebooks…", systemImage: "graduationcap")
        }
    }
}
