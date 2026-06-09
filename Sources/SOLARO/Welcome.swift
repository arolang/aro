// ============================================================
// Welcome.swift
// SOLARO — first-launch welcome screen (ADR-008)
// ============================================================
//
// Wireframe target: note 8467 figure 9 (welcome / onboarding).
// Centered wordmark + tagline, two large action cards (Open
// folder / Create project), recent-projects list below. Dark
// backdrop with subtle radial glow behind the wordmark.

import SwiftUI
import AppKit

struct WelcomeView: View {
    let runtimeVersion: String
    let onOpen: (Project) -> Void

    @Environment(\.openWindow) private var openWindow
    @State private var recents: [Project] = RecentProjects.load()
    @State private var errorText: String?

    var body: some View {
        ZStack {
            // Backdrop with a subtle radial accent glow behind the
            // wordmark — wireframes call for "soft halo, not loud".
            SolaroColor.backdrop
                .overlay(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            SolaroColor.accent.opacity(0.18),
                            SolaroColor.accent.opacity(0.00),
                        ]),
                        center: .center, startRadius: 1, endRadius: 360
                    )
                    .frame(width: 720, height: 720)
                    .offset(y: -80)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                )

            VStack(spacing: SolaroSpace.xxl) {
                Spacer()
                wordmark
                actionTiles
                if !recents.isEmpty {
                    recentsSection
                }
                Spacer()
                if let errorText {
                    Text(errorText)
                        .font(SolaroFont.caption)
                        .foregroundStyle(SolaroColor.stateError)
                        .padding(.bottom, SolaroSpace.m)
                }
                Text("v\(runtimeVersion)  ·  ARO runtime embedded")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textTertiary)
                    .padding(.bottom, SolaroSpace.l)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, SolaroSpace.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Wordmark

    private var wordmark: some View {
        VStack(spacing: SolaroSpace.s) {
            Text("Solaro")
                .font(SolaroFont.wordmark)
                .tracking(10)
                .foregroundStyle(SolaroColor.textPrimary)
            Text("canvas-first IDE for ARO")
                .font(SolaroFont.body)
                .foregroundStyle(SolaroColor.textSecondary)
                .tracking(2)
        }
    }

    // MARK: - Action tiles

    private var actionTiles: some View {
        HStack(spacing: SolaroSpace.l) {
            WelcomeActionTile(
                icon: "folder",
                title: "Open folder…",
                subtitle: "Open an existing ARO project"
            ) {
                openFolder()
            }
            WelcomeActionTile(
                icon: "plus.rectangle.on.folder",
                title: "Create project…",
                subtitle: "Scaffold a new ARO project"
            ) {
                createProject()
            }
        }
    }

    // MARK: - Recents

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            HStack {
                Text("RECENT PROJECTS")
                    .font(SolaroFont.sectionTitle)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .tracking(2)
                Spacer()
                Button {
                    RecentProjects.clear()
                    recents = []
                } label: {
                    Text("Clear")
                        .font(SolaroFont.caption)
                        .foregroundStyle(SolaroColor.textTertiary)
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: SolaroSpace.m),
                          GridItem(.flexible(), spacing: SolaroSpace.m)],
                spacing: SolaroSpace.m
            ) {
                ForEach(recents) { project in
                    RecentProjectCard(
                        project: project,
                        onOpen: { openProject(project) },
                        onOpenInNewWindow: { openInNewWindow(project) },
                        onRemove: { removeRecent(project) }
                    )
                }
            }
        }
        .padding(.top, SolaroSpace.m)
    }

    private func openInNewWindow(_ project: Project) {
        // Per #276: ⌘-click opens the project in a fresh SwiftUI
        // window. We can't pass an argument through `openWindow`
        // because the WindowGroup is value-less, so we hand the
        // project off via a one-shot global slot that the new
        // RootView consumes on its first appearance.
        PendingNewWindowProject.queue(project)
        openWindow(id: SolaroWindowID.workspace)
    }

    private func removeRecent(_ project: Project) {
        RecentProjects.forget(project)
        recents.removeAll { $0.rootPath == project.rootPath }
    }

    // MARK: - Actions

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.title = "Open ARO project"
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let project = Project(rootPath: url)
        RecentProjects.remember(project)
        onOpen(project)
    }

    private func createProject() {
        let panel = NSSavePanel()
        panel.title = "Create ARO project"
        panel.prompt = "Create"
        panel.nameFieldStringValue = "MyApp"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let mainAro = url.appendingPathComponent("main.aro")
            let scaffold = """
            (* Welcome to your new ARO project *)
            (* Application-Start runs first when you `aro run` this folder. *)

            (Application-Start: \(url.lastPathComponent)) {
                Log "Hello from \(url.lastPathComponent)!" to the <console>.
                Return an <OK: status> for the <startup>.
            }
            """
            try scaffold.write(to: mainAro, atomically: true, encoding: .utf8)
            // Drop an `aro.yaml` next to main.aro so the project
            // root is unambiguous (the layout sidecar and the
            // build script both use that marker) and so the user
            // has a stub for project-level config to grow into.
            let aroYaml = url.appendingPathComponent("aro.yaml")
            let yamlStub = """
            # \(url.lastPathComponent) — ARO project manifest
            name: \(url.lastPathComponent)
            version: 0.1.0
            entrypoint: main.aro
            """
            try yamlStub.write(to: aroYaml, atomically: true, encoding: .utf8)
            let project = Project(rootPath: url)
            RecentProjects.remember(project)
            onOpen(project)
        } catch {
            errorText = "Could not create project: \(error.localizedDescription)"
        }
    }

    private func openProject(_ project: Project) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: project.rootPath.path, isDirectory: &isDir
        )
        guard exists && isDir.boolValue else {
            errorText = "Project no longer exists: \(project.rootPath.path)"
            return
        }
        RecentProjects.remember(project)
        onOpen(project)
    }
}

// MARK: - Welcome subviews

private struct WelcomeActionTile: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: SolaroSpace.s) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(SolaroColor.accent)
                Spacer().frame(height: SolaroSpace.s)
                Text(title)
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(SolaroColor.textPrimary)
                Text(subtitle)
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textSecondary)
            }
            .frame(width: 230, height: 140, alignment: .topLeading)
            .padding(SolaroSpace.l)
            .background(
                SolaroColor.surfaceRaised
                    .opacity(hovering ? 1.0 : 0.7)
            )
            .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.l, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SolaroRadius.l, style: .continuous)
                    .stroke(
                        hovering ? SolaroColor.accent.opacity(0.6) : SolaroColor.divider,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Each recent project gets one of these cards on the welcome
/// screen (#276). The card shows the project name + path plus a
/// row of subtle metadata chips — last modified, feature-set
/// count, git branch + ahead/behind — that load asynchronously
/// off the main actor. Click opens, ⌘-click opens in a new
/// window, right-click surfaces Remove / Reveal in Finder.
private struct RecentProjectCard: View {
    let project: Project
    let onOpen: () -> Void
    let onOpenInNewWindow: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false
    @State private var metadata: RecentProjectMetadata = .empty
    @State private var loaded = false

    var body: some View {
        Button {
            if NSEvent.modifierFlags.contains(.command) {
                onOpenInNewWindow()
            } else {
                onOpen()
            }
        } label: {
            cardBody
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Open in New Window") { onOpenInNewWindow() }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.rootPath])
            }
            Divider()
            Button("Remove from List", role: .destructive, action: onRemove)
        }
        .task {
            // Run once per card instance. Pulled off the main
            // actor inside the loader — the .task block itself
            // is `@MainActor` so we await the result before
            // storing it in @State.
            guard !loaded else { return }
            loaded = true
            metadata = await RecentProjectMetadataLoader.load(project)
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: SolaroSpace.s) {
            HStack(alignment: .top, spacing: SolaroSpace.s) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(SolaroColor.accent.opacity(0.85))
                    .frame(width: 20, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.displayName)
                        .font(SolaroFont.bodyBold)
                        .foregroundStyle(SolaroColor.textPrimary)
                        .lineLimit(1)
                    Text(project.rootPath.path)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            metadataRow
        }
        .padding(SolaroSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            SolaroColor.surfaceRaised.opacity(hovering ? 0.95 : 0.55)
        )
        .clipShape(RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.m, style: .continuous)
                .stroke(
                    hovering ? SolaroColor.accent.opacity(0.55) : SolaroColor.divider,
                    lineWidth: 1
                )
        )
    }

    /// Subtle row of metadata chips. Each piece renders only if
    /// the loader produced a value — a stale entry that can't be
    /// reached, or a non-repo folder, just shows fewer chips
    /// rather than empty placeholders.
    private var metadataRow: some View {
        HStack(spacing: SolaroSpace.s) {
            if let stamp = metadata.lastModified {
                MetadataChip(
                    icon: "clock",
                    text: Self.relativeDateFormatter.localizedString(
                        for: stamp, relativeTo: Date()
                    )
                )
            }
            if let count = metadata.featureSetCount {
                MetadataChip(
                    icon: "square.stack.3d.up",
                    text: "\(count) feature set\(count == 1 ? "" : "s")"
                )
            }
            if let git = metadata.git {
                GitChip(status: git)
            }
            Spacer(minLength: 0)
        }
        .font(SolaroFont.caption)
        .foregroundStyle(SolaroColor.textSecondary)
    }

    static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

private struct MetadataChip: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(SolaroColor.surfaceRaised.opacity(0.5))
        )
    }
}

private struct GitChip: View {
    let status: RecentProjectMetadata.GitStatus
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
            Text(status.branch + (status.dirty ? "*" : ""))
            if status.ahead > 0 {
                Text("↑\(status.ahead)")
                    .foregroundStyle(SolaroColor.stateOK)
            }
            if status.behind > 0 {
                Text("↓\(status.behind)")
                    .foregroundStyle(SolaroColor.stateWarn)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(SolaroColor.surfaceRaised.opacity(0.5))
        )
    }
}

/// One-shot hand-off used when the welcome screen opens a recent
/// project in a brand-new window via ⌘-click. SwiftUI's
/// `openWindow(id:)` on a value-less WindowGroup gives us a fresh
/// `RootView`, but it has no way to pass an argument; the new
/// RootView pops the queue on first appearance and routes itself
/// straight into the workspace. The queue is a list (not a single
/// slot) so back-to-back ⌘-clicks don't clobber each other.
@MainActor
enum PendingNewWindowProject {
    private static var pending: [Project] = []

    static func queue(_ project: Project) {
        pending.append(project)
    }

    static func take() -> Project? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}

/// Canonical IDs for our `WindowGroup`s so we can reach them via
/// the `openWindow` environment action.
enum SolaroWindowID {
    static let workspace = "solaro-workspace"
}
