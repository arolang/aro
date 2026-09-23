// ============================================================
// WorkspaceCommands.swift
// SOLARO — the menu router (#772)
// ============================================================
//
// One roughly forty-case switch, moved out of `Workspace.swift` whole.
// It sat in the middle of a file that was also a view body with fifteen
// sheet modifiers, an LSP client and a git driver — and the compiler
// had begun to object, with two handlers already extracted because "the
// Swift type-checker started timing out trying to infer it in-place".
//
// An extension on `WorkspaceView` rather than a separate router type:
// every case reaches into the view's own `@State` to open a sheet or
// flip a pane, so a standalone object would need a binding per piece of
// state and would be more machinery than the split buys.

import SwiftUI
import AppKit

extension WorkspaceView {

    /// Route a menu-bar action to the right handler. Centralised
    /// dispatch keeps the menu definitions in `SOLAROApp.swift`
    /// data-driven (each item only knows the action ID) and stops
    /// us from threading 30+ named notifications.
    func handleMenuAction(_ action: SolaroMenuAction) {
        switch action {
        // File
        case .fileRevealInFinder:
            if let url = controller.currentFile {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .fileCopyPath:
            if let url = controller.currentFile {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(url.path, forType: .string)
            }
        case .fileRename:
            // Inline rename via NSAlert — the sidebar uses a
            // SwiftUI alert with a TextField, but we'd have to
            // route a Binding through the menu observer to share
            // it. NSAlert is shorter and equally functional from
            // a menu-driven entry point.
            if let url = controller.currentFile {
                renameCurrentFile(at: url)
            }
        case .fileMoveToTrash:
            // Prefer whatever's highlighted in the Files panel —
            // if the user picked a folder there, that's what they
            // mean to delete, not the file they happen to have
            // open in the editor (#?).
            if let url = controller.treeFocus
                ?? controller.currentFile {
                pendingDeleteFile = url
            }
        case .fileCloseTab:
            if let url = controller.currentFile {
                controller.closeTab(url)
            }
        case .fileReload:
            // File → Reload from Disk (GitLab #536). The comment in
            // `load()` promised this menu item for a year.
            controller.reloadFromDisk()
        // Edit
        case .editFindInFile:
            handleFindInFile()
        case .editFindInProject:
            showFindInProject = true
        case .editFormatDocument:
            formatDocument()
        case .editRenameRefactor:
            beginRename()
        case .editTriggerCompletion:
            triggerCompletion()
        // View
        case .viewToggleSidebar:
            controller.sidebarShown.toggle()
        case .viewToggleInspector:
            controller.inspectorShown.toggle()
        case .viewPaneMap:    controller.setPaneMode(.map)
        case .viewPaneCanvas: controller.setPaneMode(.canvas)
        case .viewPaneText:   controller.setPaneMode(.text)
        case .viewPaneSplit:  controller.setPaneMode(.split)
        case .viewCommandPalette:
            showCommandPalette = true
        case .viewZoomIn:
            EditorTypography.zoom(.in)
        case .viewZoomOut:
            EditorTypography.zoom(.out)
        case .viewZoomReset:
            EditorTypography.zoom(.reset)
        case .viewQuickOpen:
            showQuickOpen = true
        case .viewSymbolPalette:
            showSymbolPalette = true
        // Navigate
        case .navGoToDefinition: goToDefinition()
        case .navFindReferences: findReferences()
        case .navHover:          hoverAtCaret()
        case .navNextTab:        controller.cycleTab(by: 1)
        case .navPrevTab:        controller.cycleTab(by: -1)
        // Run
        case .runPlay:           requestRun()
        case .runDebug:          requestDebug()
        case .runTests:
            showConsole = true
            consoleProcess.startTests(project: project)
        case .runStop:           consoleProcess.stop()
        case .runBuild:          showBuildSheet = true
        case .runCheck:
            showConsole = true
            consoleProcess.startCheck(project: project)
        case .runAutoLayout:
            NotificationCenter.default.post(
                name: .solaroResetCanvasLayout, object: nil
            )
        case .runExportCanvas:   exportCanvasPNG()
        case .runTimeTravel:     showTimeTravel = true
        // Git
        case .gitCommit:         openCommitOverlay()
        case .gitGraphDiff:      showGraphDiff = true
        case .gitBlame:          showBlame()
        case .gitRevertFile:
            guard let url = controller.currentFile,
                  let status = controller.gitMonitor.status.files[url.path]
            else { return }
            Task {
                _ = await controller.gitMonitor.revertLocalChanges(
                    in: project, path: url.path, status: status
                )
            }
        // AI
        case .aiOpenPanel:
            controller.rightPaneMode = .coPilot
            controller.inspectorShown = true
        case .aiReset:
            controller.aiCoPilot.reset(in: project)
        }
    }}
