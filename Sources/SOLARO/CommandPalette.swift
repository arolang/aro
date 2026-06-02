// ============================================================
// CommandPalette.swift
// SOLARO — ⌘⇧P palette listing every action (#235)
// ============================================================

import SwiftUI
import AppKit

enum CommandPaletteBuilder {

    /// Compose the command list from current workspace state. The
    /// list is recomputed per palette open so it always reflects
    /// the live mode + selection.
    @MainActor
    static func items(
        controller: WorkspaceController,
        project: Project,
        consoleProcess: ConsoleProcess,
        onSwitchPaneMode: @escaping (PaneMode) -> Void,
        onCloseProject: @escaping () -> Void,
        onOpenQuickOpen: @escaping () -> Void,
        onOpenFindReplace: @escaping () -> Void,
        onOpenOpenAPIPalette: @escaping () -> Void,
        onOpenTimeTravel: @escaping () -> Void,
        onOpenAddPlugin: @escaping () -> Void,
        onGoToDefinition: @escaping () -> Void
    ) -> [PaletteItem] {
        var items: [PaletteItem] = []

        // Run / Debug
        items.append(.init(
            id: "run",
            title: "Run",
            subtitle: "aro run \(project.displayName)",
            category: "Run",
            trailing: nil,
            symbol: "play.fill",
            action: { consoleProcess.startRun(project: project) }
        ))
        items.append(.init(
            id: "debug",
            title: "Debug",
            subtitle: "aro debug — pauses at every breakpoint",
            category: "Run",
            trailing: nil,
            symbol: "ant.fill",
            action: {
                consoleProcess.startDebug(
                    project: project,
                    breakpointsByFile: Self.collectBreakpoints(controller: controller)
                )
            }
        ))
        items.append(.init(
            id: "test",
            title: "Run tests",
            subtitle: "aro test \(project.displayName)",
            category: "Run",
            trailing: "⌃⌘U",
            symbol: "checkmark.diamond",
            action: { consoleProcess.startTests(project: project) }
        ))
        items.append(.init(
            id: "stop",
            title: "Stop running process",
            subtitle: nil,
            category: "Run",
            trailing: nil,
            symbol: "stop.fill",
            action: { consoleProcess.stop() }
        ))

        // View
        for mode in PaneMode.allCases {
            items.append(.init(
                id: "mode:\(mode.rawValue)",
                title: "Switch to \(mode.label) mode",
                subtitle: nil,
                category: "View",
                trailing: nil,
                symbol: mode.symbol,
                action: { onSwitchPaneMode(mode) }
            ))
        }
        items.append(.init(
            id: "toggle-inspector",
            title: controller.inspectorShown
                ? "Hide right rail"
                : "Show right rail",
            subtitle: nil,
            category: "View",
            trailing: nil,
            symbol: "sidebar.right",
            action: { controller.inspectorShown.toggle() }
        ))
        items.append(.init(
            id: "rp-inspector",
            title: "Right rail · Inspector",
            subtitle: nil,
            category: "View",
            trailing: nil,
            symbol: "sidebar.right",
            action: { controller.rightPaneMode = .inspector }
        ))
        items.append(.init(
            id: "rp-actions",
            title: "Right rail · Actions",
            subtitle: nil,
            category: "View",
            trailing: nil,
            symbol: "puzzlepiece.fill",
            action: { controller.rightPaneMode = .actions }
        ))
        items.append(.init(
            id: "rp-ask",
            title: "Right rail · Ask",
            subtitle: nil,
            category: "View",
            trailing: nil,
            symbol: "sparkles",
            action: { controller.rightPaneMode = .coPilot }
        ))

        // Sidebar tabs
        for tab in SidebarTab.allCases {
            items.append(.init(
                id: "tab:\(tab.rawValue)",
                title: "Sidebar · \(tab.label)",
                subtitle: nil,
                category: "View",
                trailing: nil,
                symbol: tab.symbol,
                action: { controller.sidebarTab = tab }
            ))
        }

        // File
        items.append(.init(
            id: "find-file",
            title: "Quick Open File…",
            subtitle: "Fuzzy-search every file in the project",
            category: "File",
            trailing: "⌘P",
            symbol: "magnifyingglass",
            action: { onOpenQuickOpen() }
        ))
        items.append(.init(
            id: "find-in-project",
            title: "Find in Project…",
            subtitle: "Search across every file",
            category: "File",
            trailing: "⇧⌘F",
            symbol: "text.magnifyingglass",
            action: { onOpenFindReplace() }
        ))
        items.append(.init(
            id: "go-to-definition",
            title: "Go to Definition",
            subtitle: "Jump to where the symbol on this line is declared",
            category: "File",
            trailing: "⌃⌘D",
            symbol: "arrow.right.to.line",
            action: { onGoToDefinition() }
        ))
        items.append(.init(
            id: "reveal",
            title: "Reveal project in Finder",
            subtitle: project.rootPath.path,
            category: "File",
            trailing: nil,
            symbol: "folder",
            action: {
                NSWorkspace.shared.activateFileViewerSelecting([project.rootPath])
            }
        ))
        items.append(.init(
            id: "close-project",
            title: "Close project",
            subtitle: nil,
            category: "File",
            trailing: nil,
            symbol: "xmark.circle",
            action: { onCloseProject() }
        ))

        // OpenAPI (when relevant)
        if let document = controller.openAPIDocument {
            items.append(.init(
                id: "openapi-add-route",
                title: "OpenAPI · Add route",
                subtitle: "Inserts /newRoute with a 200 stub",
                category: "OpenAPI",
                trailing: nil,
                symbol: "plus.rectangle.on.rectangle",
                action: {
                    let added = document.addRoute()
                    controller.openAPISelectedNodeID =
                        "route:\(added.method) \(added.path)"
                }
            ))
            items.append(.init(
                id: "openapi-add-schema",
                title: "OpenAPI · Add schema",
                subtitle: "Inserts NewType with an id field",
                category: "OpenAPI",
                trailing: nil,
                symbol: "plus.square.on.square",
                action: {
                    let name = document.addSchema()
                    controller.openAPISelectedNodeID = "schema:\(name)"
                }
            ))
            items.append(.init(
                id: "openapi-save",
                title: "OpenAPI · Save document",
                subtitle: nil,
                category: "OpenAPI",
                trailing: nil,
                symbol: "square.and.arrow.down",
                action: { document.save() }
            ))
        }

        // Plugins
        items.append(.init(
            id: "install-plugin",
            title: "Install plugin from Git…",
            subtitle: "Runs aro add <url>",
            category: "Plugins",
            trailing: nil,
            symbol: "puzzlepiece.extension",
            action: { onOpenAddPlugin() }
        ))

        // Bottom-panel actions
        items.append(.init(
            id: "openapi-palette",
            title: "Open OpenAPI palette",
            subtitle: nil,
            category: "Bottom",
            trailing: "⌘K",
            symbol: "rectangle.stack.badge.plus",
            action: { onOpenOpenAPIPalette() }
        ))
        items.append(.init(
            id: "time-travel",
            title: "Open Time Travel",
            subtitle: "Scrub the most recent debug recording",
            category: "Bottom",
            trailing: nil,
            symbol: "clock.arrow.circlepath",
            action: { onOpenTimeTravel() }
        ))

        // Help
        items.append(.init(
            id: "report-bug",
            title: "Report a Bug…",
            subtitle: nil,
            category: "Help",
            trailing: "⇧⌘?",
            symbol: "exclamationmark.bubble",
            action: { CrashReporter.openReportBugPage() }
        ))
        items.append(.init(
            id: "reveal-crash-logs",
            title: "Reveal crash logs in Finder",
            subtitle: nil,
            category: "Help",
            trailing: nil,
            symbol: "ladybug",
            action: {
                NSWorkspace.shared.open(CrashReporter.crashesDirectory)
            }
        ))

        return items
    }

    @MainActor
    private static func collectBreakpoints(
        controller: WorkspaceController
    ) -> [URL: Set<Int>] {
        guard let model = controller.model else { return [:] }
        var out: [URL: Set<Int>] = [:]
        for url in model.sourceFiles {
            let sidecar = LayoutSidecar.load(for: url)
            if !sidecar.breakpoints.isEmpty {
                out[url] = sidecar.breakpoints
            }
        }
        return out
    }
}
