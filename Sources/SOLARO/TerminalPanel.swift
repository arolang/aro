// ============================================================
// TerminalPanel.swift
// SOLARO — real ANSI terminal in the bottom panel (#244)
// ============================================================
//
// Wraps SwiftTerm's `LocalProcessTerminalView` in an NSViewRepresentable
// so the bottom panel can host a full PTY-backed shell next to the
// captured-output Console.

import SwiftUI
import AppKit
import SwiftTerm

struct TerminalView: NSViewRepresentable {
    let workingDirectory: URL

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.processDelegate = context.coordinator
        // Reasonable defaults — SOLARO's dark backdrop matches a
        // classic terminal scheme.
        terminal.nativeBackgroundColor = NSColor(SolaroColor.backdrop)
        terminal.nativeForegroundColor = NSColor(SolaroColor.textPrimary)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // Use the user's login shell so PATH + dotfiles work as
        // expected, started in the project directory.
        let shell = ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
        terminal.startProcess(
            executable: shell,
            args: ["-l"],
            environment: nil,
            execName: nil
        )
        // Drop into the project dir on first prompt.
        let cdCommand = "cd \"\(workingDirectory.path)\"\n"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            terminal.send(txt: cdCommand)
        }
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // No live binding to push back — the terminal owns its state.
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        func sizeChanged(source: LocalProcessTerminalView,
                         newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView,
                              title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView,
                                        directory: String?) {}
        func processTerminated(source: SwiftTerm.TerminalView,
                               exitCode: Int32?) {}
    }
}
