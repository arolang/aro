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

    var body: some View {
        HStack(spacing: SolaroSpace.m) {
            filePathSegment
            Divider().frame(height: 14).background(SolaroColor.divider)
            parseStateSegment

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
                Circle().fill(SolaroColor.stateError).frame(width: 6, height: 6)
                Text("parse error")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.stateError)
            } else if let program = controller.currentProgram {
                Circle().fill(SolaroColor.stateOK).frame(width: 6, height: 6)
                Text("\(program.featureSets.count) feature set\(program.featureSets.count == 1 ? "" : "s")")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textSecondary)
            } else {
                Circle().fill(SolaroColor.textTertiary).frame(width: 6, height: 6)
                Text("no file")
                    .font(SolaroFont.monoCaption)
                    .foregroundStyle(SolaroColor.textTertiary)
            }
        }
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
