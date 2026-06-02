// ============================================================
// StatusBar.swift
// SOLARO — bottom status bar (Phase 11)
// ============================================================
//
// Wireframe target: note 8467 figure 11 (status bar).
//
// Thin one-line strip across the bottom of the workspace window.
// Reads from WorkspaceController so every state shown here is
// fresh — no separate refresh logic.

import SwiftUI
import AROVersion

struct StatusBarView: View {
    @Bindable var controller: WorkspaceController

    let onShowOpenAPIPalette: () -> Void
    let onShowTimeTravel: () -> Void
    let onShowCommitOverlay: () -> Void

    @State private var showBranchPicker: Bool = false
    @State private var branchSwitchError: String?
    @State private var branchSwitching: String?

    var body: some View {
        HStack(spacing: SolaroSpace.m) {
            filePathSegment
            Divider().frame(height: 14).background(SolaroColor.divider)
            parseStateSegment

            if controller.gitMonitor.isAvailable {
                Divider().frame(height: 14).background(SolaroColor.divider)
                gitChip
            }

            Spacer(minLength: 0)

            paletteButton
            timeTravelButton
            Divider().frame(height: 14).background(SolaroColor.divider)
            runtimeSegment
        }
        .padding(.horizontal, SolaroSpace.m)
        .frame(height: 26)
        .background(SolaroColor.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(SolaroColor.divider)
                .frame(height: 1)
        }
    }

    private var filePathSegment: some View {
        HStack(spacing: SolaroSpace.xs) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(SolaroColor.textTertiary)
            Text(relativePath)
                .font(SolaroFont.monoCaption)
                .foregroundStyle(SolaroColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var parseStateSegment: some View {
        HStack(spacing: SolaroSpace.xs) {
            if controller.currentParseError != nil {
                statePip(color: SolaroColor.stateError)
                Text("parse error")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.stateError)
            } else if let program = controller.currentProgram {
                statePip(color: SolaroColor.stateOK)
                Text("\(program.featureSets.count) feature set\(program.featureSets.count == 1 ? "" : "s")")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textSecondary)
            } else {
                statePip(color: SolaroColor.textTertiary)
                Text("no file")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
        }
    }

    private var gitChip: some View {
        let s = controller.gitMonitor.status
        return HStack(spacing: SolaroSpace.xs) {
            // Branch button — clicking opens a popover with every
            // local branch; clicking a name runs `git checkout`.
            Button {
                showBranchPicker.toggle()
            } label: {
                HStack(spacing: SolaroSpace.xs) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                        .foregroundStyle(SolaroColor.textSecondary)
                    Text(s.branch.isEmpty ? "(detached)" : s.branch)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .help("Switch branch — \(gitTooltip)")
            .popover(isPresented: $showBranchPicker, arrowEdge: .top) {
                branchPicker
            }
            if s.ahead > 0 {
                Label("\(s.ahead)", systemImage: "arrow.up")
                    .labelStyle(.titleAndIcon)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.stateOK)
            }
            if s.behind > 0 {
                Label("\(s.behind)", systemImage: "arrow.down")
                    .labelStyle(.titleAndIcon)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.stateWarn)
            }
            if !s.files.isEmpty {
                // Separator dot — kept *outside* the button so the
                // hover underline only ranges across "N changed",
                // not the leading "·  ".
                Text("·")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
                Button {
                    onShowCommitOverlay()
                } label: {
                    Text("\(s.files.count) changed")
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.accent)
                        .underline()
                }
                .buttonStyle(.plain)
                .help("Open commit overlay")
            }
        }
    }

    private var branchPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "arrow.triangle.branch")
                Text("Switch branch")
                    .font(SolaroFont.sectionTitle)
                    .tracking(2)
                    .foregroundStyle(SolaroColor.textSecondary)
                Spacer()
            }
            .padding(SolaroSpace.s)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if controller.gitMonitor.branches.isEmpty {
                        Text("(no local branches)")
                            .font(SolaroFont.monoCaption)
                            .foregroundStyle(SolaroColor.textTertiary)
                            .padding(SolaroSpace.s)
                    } else {
                        ForEach(controller.gitMonitor.branches) { branch in
                            branchRow(branch)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
            if let err = branchSwitchError {
                Divider()
                HStack(alignment: .top, spacing: SolaroSpace.xs) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(SolaroColor.stateError)
                    Text(err)
                        .font(SolaroFont.monoCaption)
                        .foregroundStyle(SolaroColor.stateError)
                        .textSelection(.enabled)
                }
                .padding(SolaroSpace.s)
            }
        }
        .frame(width: 280)
        .background(SolaroColor.surface)
    }

    @ViewBuilder
    private func branchRow(_ branch: GitBranch) -> some View {
        Button {
            switchToBranch(branch)
        } label: {
            HStack {
                if branch.isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(SolaroColor.stateOK)
                        .frame(width: 14)
                } else if branchSwitching == branch.name {
                    ProgressView().controlSize(.mini).frame(width: 14)
                } else {
                    Color.clear.frame(width: 14)
                }
                Text(branch.name)
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(branch.isCurrent
                                     ? SolaroColor.textPrimary
                                     : SolaroColor.textSecondary)
                Spacer()
            }
            .padding(.horizontal, SolaroSpace.s)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(branch.isCurrent || branchSwitching != nil)
        .background(
            branch.isCurrent
                ? SolaroColor.accent.opacity(0.08)
                : Color.clear
        )
    }

    private func switchToBranch(_ branch: GitBranch) {
        guard !branch.isCurrent,
              let project = controller.model?.root
        else { return }
        branchSwitching = branch.name
        branchSwitchError = nil
        Task {
            let err = await controller.gitMonitor.checkout(
                branch: branch.name, in: project
            )
            branchSwitching = nil
            if let err {
                branchSwitchError = err
            } else {
                showBranchPicker = false
            }
        }
    }

    private var gitTooltip: String {
        let s = controller.gitMonitor.status
        var lines = ["branch: \(s.branch)"]
        if !s.upstream.isEmpty { lines.append("upstream: \(s.upstream)") }
        lines.append("ahead \(s.ahead) · behind \(s.behind)")
        if !s.files.isEmpty {
            lines.append("\(s.files.count) changed files")
        }
        return lines.joined(separator: "\n")
    }

    /// Shared 6pt SF Symbol state pip — keeps every dot in the
    /// app consistent and avoids hand-rolled Circle shapes.
    private func statePip(color: Color) -> some View {
        Image(systemName: "circle.fill")
            .resizable()
            .frame(width: 6, height: 6)
            .foregroundStyle(color)
    }

    private var paletteButton: some View {
        Button(action: onShowOpenAPIPalette) {
            HStack(spacing: SolaroSpace.xs) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 10))
                Text("OpenAPI ⌘K")
                    .font(SolaroFont.monoCaption)
            }
            .foregroundStyle(SolaroColor.textTertiary)
        }
        .buttonStyle(.plain)
        .help("Open the OpenAPI endpoint palette (⌘K)")
        .keyboardShortcut("k", modifiers: .command)
    }

    private var timeTravelButton: some View {
        Button(action: onShowTimeTravel) {
            HStack(spacing: SolaroSpace.xs) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                Text("Time travel")
                    .font(SolaroFont.monoCaption)
            }
            .foregroundStyle(SolaroColor.textTertiary)
        }
        .buttonStyle(.plain)
        .help("Replay the most recent run from .solaro/events.jsonl")
    }

    private var runtimeSegment: some View {
        Text("runtime \(AROVersion.shortVersion)")
            .font(SolaroFont.monoCaption)
            .foregroundStyle(SolaroColor.textTertiary)
    }

    private var relativePath: String {
        guard let url = controller.currentFile,
              let model = controller.model else { return "(no file)" }
        let rootPath = model.root.rootPath.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }
}
