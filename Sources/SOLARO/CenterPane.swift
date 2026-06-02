// ============================================================
// CenterPane.swift
// SOLARO — center pane dispatcher (Phase 7 onwards)
// ============================================================
//
// Dispatches the right view for the current pane mode. Phase 7
// ships the Text mode (CodeEditor); Phases 8/10 add Canvas, Split,
// and Map. The shared empty-state UI lives here so each mode's
// view can stay focused.

import SwiftUI
import AROParser

struct CenterPaneView: View {
    @Bindable var controller: WorkspaceController

    var body: some View {
        Group {
            if controller.currentFile == nil, controller.paneMode != .map {
                emptyPane("Select a file from the sidebar.")
            } else {
                switch controller.paneMode {
                case .text:   textMode
                case .canvas: canvasMode
                case .split:  splitMode
                case .map:    mapMode
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SolaroColor.backdrop)
    }

    // MARK: - Text

    @ViewBuilder
    private var textMode: some View {
        if let url = controller.currentFile {
            AROCodeEditor(
                text: editableBinding(for: url),
                onSave: { saveAndReparse(text: $0, url: url) }
            )
        }
    }

    private func editableBinding(for url: URL) -> Binding<String> {
        Binding(
            get: { (try? String(contentsOf: url, encoding: .utf8)) ?? "" },
            set: { newValue in
                try? newValue.write(to: url, atomically: true, encoding: .utf8)
                reparse(url: url)
            }
        )
    }

    private func saveAndReparse(text: String, url: URL) {
        try? text.write(to: url, atomically: true, encoding: .utf8)
        reparse(url: url)
    }

    private func reparse(url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            controller.parseErrors[url] = "Could not read file."
            controller.programs.removeValue(forKey: url)
            return
        }
        do {
            controller.programs[url] = try Parser.parse(text)
            controller.parseErrors.removeValue(forKey: url)
        } catch {
            controller.parseErrors[url] = "\(error)"
        }
    }

    // MARK: - Canvas / Split / Map (Phases 8 and 10)

    @ViewBuilder
    private var canvasMode: some View {
        emptyPane("Canvas mode lands in Phase 8.")
    }

    @ViewBuilder
    private var splitMode: some View {
        emptyPane("Split mode lands in Phase 10.")
    }

    @ViewBuilder
    private var mapMode: some View {
        emptyPane("Map mode lands in Phase 10.")
    }

    // MARK: - Helpers

    private func emptyPane(_ text: String) -> some View {
        VStack(spacing: SolaroSpace.s) {
            Image(systemName: controller.paneMode.symbol)
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(SolaroColor.textTertiary)
            Text(controller.paneMode.label)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(SolaroColor.textSecondary)
            Text(text)
                .font(SolaroFont.caption)
                .foregroundStyle(SolaroColor.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
