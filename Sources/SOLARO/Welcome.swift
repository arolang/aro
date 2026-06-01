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
            Text("SOLARO")
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

            VStack(spacing: SolaroSpace.xs) {
                ForEach(recents) { project in
                    RecentProjectRow(project: project) {
                        openProject(project)
                    }
                }
            }
        }
        .padding(.top, SolaroSpace.m)
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

private struct RecentProjectRow: View {
    let project: Project
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SolaroSpace.m) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(SolaroColor.accent.opacity(0.8))
                    .frame(width: 18, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.displayName)
                        .font(SolaroFont.body)
                        .foregroundStyle(SolaroColor.textPrimary)
                    Text(project.rootPath.path)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.vertical, SolaroSpace.s)
            .padding(.horizontal, SolaroSpace.m)
            .background(
                RoundedRectangle(cornerRadius: SolaroRadius.s, style: .continuous)
                    .fill(hovering ? SolaroColor.selection : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
