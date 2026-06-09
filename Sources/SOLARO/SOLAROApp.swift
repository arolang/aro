// ============================================================
// SOLAROApp.swift
// SOLARO — canvas-first IDE for ARO (issue #228)
// ============================================================
//
// Entry point for the SOLARO desktop app. Per ADR-001 (revised
// 2026-06) SOLARO is a native macOS app built directly on SwiftUI
// + AppKit.
//
// Multi-window note (#251): the workspace's routing state lives
// inside RootView so SwiftUI gives each WindowGroup window its
// own copy. File → New Window (⌘N) opens a fresh welcome screen
// without touching any other window; ⌘W closes the current one.

import AppKit
import SwiftUI
import AROVersion

@main
struct SOLAROApp: App {

    /// Per ADR-003 the embedded `ARORuntime` is pinned per release;
    /// the version shown in the About panel comes from `AROVersion`.
    let runtimeVersion: String = AROVersion.shortVersion

    init() {
        // Per ADR-007 / ADR-010: install a local crash logger so
        // we can write a report to disk on fatal signals. No
        // automatic upload — the user opens an issue manually
        // via Help → Report a Bug…
        CrashReporter.install()
        // AppKit calls `_crashOnException` for any NSException raised
        // during the display cycle (e.g. Auto Layout contradictions
        // inside NavigationSplitView when the window is dragged below
        // the columns' implicit minima). The exception is recoverable
        // for our purposes — the next layout pass succeeds — so we
        // keep the app alive instead of trapping. The exception still
        // logs to stderr so we can see it during development.
        UserDefaults.standard.set(false, forKey: "NSApplicationCrashOnExceptions")
    }

    var body: some Scene {
        // WindowGroup goes first so it owns the .commands modifier
        // and so SwiftUI's auto-launched window is the main one,
        // not Settings (#276 — moving Settings before the group
        // suppressed the main window on launch).
        WindowGroup("Solaro", id: SolaroWindowID.workspace) {
            RootView(runtimeVersion: runtimeVersion)
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            // Custom Undo / Redo (see comment on SolaroUndoCommand
            // — routes between the focused NSTextView's UndoManager
            // and the workspace's UndoManager at click time).
            CommandGroup(replacing: .undoRedo) {
                SolaroUndoCommand()
                SolaroRedoCommand()
            }
            solaroFileMenu
            solaroEditMenu
            solaroViewMenu
            solaroNavigateMenu
            solaroRunMenu
            solaroGitMenu
            solaroAIMenu
            CommandGroup(after: .help) {
                Menu {
                    ForEach(Book.all, id: \.id) { book in
                        Button {
                            BookWindow.show(book)
                        } label: {
                            Label(book.title, systemImage: book.symbol)
                        }
                    }
                } label: {
                    Label("Books", systemImage: "books.vertical")
                }
                .keyboardShortcut("?", modifiers: [.command])
                Divider()
                Button {
                    CrashReporter.openReportBugPage()
                } label: {
                    Label("Report a Bug…", systemImage: "ant.fill")
                }
                .keyboardShortcut("?", modifiers: [.command, .shift])
                Button {
                    NSWorkspace.shared.open(CrashReporter.crashesDirectory)
                } label: {
                    Label("Reveal Crash Logs in Finder", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        Settings {
            SettingsView()
        }
    }

    // MARK: - Menu bar

    /// File menu additions (slots in after the .newItem / .openItem
    /// groups SwiftUI provides). SOLARO's editor auto-saves, so
    /// the menu omits explicit "Save" entries — what's left is the
    /// file-management surface: Reveal, Copy Path, Rename, Move to
    /// Trash, Close Tab.
    @CommandsBuilder
    private var solaroFileMenu: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button {
                postSolaroMenuAction(.fileRevealInFinder)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift, .option])
            Button {
                postSolaroMenuAction(.fileCopyPath)
            } label: {
                Label("Copy File Path", systemImage: "doc.on.clipboard")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift, .option])
            Button {
                postSolaroMenuAction(.fileRename)
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                postSolaroMenuAction(.fileMoveToTrash)
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            Divider()
            Button {
                postSolaroMenuAction(.fileCloseTab)
            } label: {
                Label("Close Tab", systemImage: "xmark")
            }
            .keyboardShortcut("w", modifiers: [.command])
        }
    }

    /// Edit menu — Find / Replace, refactor, format. Sits after
    /// the system-provided pasteboard items.
    @CommandsBuilder
    private var solaroEditMenu: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button {
                postSolaroMenuAction(.editFindInFile)
            } label: {
                Label("Find in File…", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: [.command])
            Button {
                postSolaroMenuAction(.editFindInProject)
            } label: {
                Label("Find in Project…", systemImage: "text.magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button {
                postSolaroMenuAction(.editFormatDocument)
            } label: {
                Label("Format Document", systemImage: "text.alignleft")
            }
            .keyboardShortcut("f", modifiers: [.option, .shift])
            Button {
                postSolaroMenuAction(.editRenameRefactor)
            } label: {
                Label("Rename Symbol…", systemImage: "character.cursor.ibeam")
            }
            .keyboardShortcut("r", modifiers: [.control, .command])
            Button {
                postSolaroMenuAction(.editTriggerCompletion)
            } label: {
                Label("Trigger Completion", systemImage: "text.append")
            }
            .keyboardShortcut(" ", modifiers: [.control])
        }
    }

    /// View menu — sidebar/inspector toggles, pane-mode picker,
    /// bottom panel reveal, internal logs.
    @CommandsBuilder
    private var solaroViewMenu: some Commands {
        CommandGroup(after: .sidebar) {
            Button {
                postSolaroMenuAction(.viewToggleSidebar)
            } label: {
                Label("Toggle Sidebar", systemImage: "sidebar.left")
            }
            .keyboardShortcut("0", modifiers: [.command])
            Button {
                postSolaroMenuAction(.viewToggleInspector)
            } label: {
                Label("Toggle Inspector", systemImage: "sidebar.right")
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Menu {
                Button {
                    postSolaroMenuAction(.viewPaneMap)
                } label: {
                    Label("Map", systemImage: "point.3.connected.trianglepath.dotted")
                }
                Button {
                    postSolaroMenuAction(.viewPaneCanvas)
                } label: {
                    Label("Canvas", systemImage: "circle.hexagongrid")
                }
                Button {
                    postSolaroMenuAction(.viewPaneText)
                } label: {
                    Label("Text", systemImage: "text.alignleft")
                }
                Button {
                    postSolaroMenuAction(.viewPaneSplit)
                } label: {
                    Label("Split", systemImage: "rectangle.split.2x1")
                }
            } label: {
                Label("Pane Mode", systemImage: "rectangle.3.group")
            }
            Divider()
            Button {
                NotificationCenter.default.post(
                    name: .solaroShowBottomPanel,
                    object: nil,
                    userInfo: ["tab": "console"]
                )
            } label: {
                Label("Show Console", systemImage: "terminal")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            Button {
                NotificationCenter.default.post(
                    name: .solaroShowBottomPanel,
                    object: nil,
                    userInfo: ["tab": "terminal"]
                )
            } label: {
                Label("Show Terminal", systemImage: "apple.terminal")
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            Button {
                NotificationCenter.default.post(
                    name: .solaroShowBottomPanel,
                    object: nil,
                    userInfo: ["tab": "tests"]
                )
            } label: {
                Label("Show Tests", systemImage: "checkmark.diamond")
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            Divider()
            Button {
                InternalLogsWindow.show()
            } label: {
                Label("Internal Logs…", systemImage: "doc.text")
            }
            .keyboardShortcut("l", modifiers: [.command, .shift, .option])
        }
    }

    /// Navigate menu — palettes, jump-to, tab cycling.
    @CommandsBuilder
    private var solaroNavigateMenu: some Commands {
        CommandMenu("Navigate") {
            Button {
                postSolaroMenuAction(.navGoToDefinition)
            } label: {
                Label("Go to Definition", systemImage: "arrow.right.circle")
            }
            .keyboardShortcut("d", modifiers: [.control, .command])
            Button {
                postSolaroMenuAction(.navHover)
            } label: {
                Label("Show Hover Info", systemImage: "info.circle")
            }
            .keyboardShortcut("h", modifiers: [.control, .command])
            Divider()
            Button {
                postSolaroMenuAction(.viewCommandPalette)
            } label: {
                Label("Command Palette…", systemImage: "command")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Button {
                postSolaroMenuAction(.viewQuickOpen)
            } label: {
                Label("Quick Open…", systemImage: "doc.text.magnifyingglass")
            }
            .keyboardShortcut("p", modifiers: [.command])
            Button {
                postSolaroMenuAction(.viewSymbolPalette)
            } label: {
                Label("Symbol Palette…", systemImage: "list.bullet.rectangle")
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button {
                postSolaroMenuAction(.navNextTab)
            } label: {
                Label("Next Tab", systemImage: "arrow.right")
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            Button {
                postSolaroMenuAction(.navPrevTab)
            } label: {
                Label("Previous Tab", systemImage: "arrow.left")
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
        }
    }

    /// Run menu — Play / Debug / Tests / Stop, canvas tooling.
    @CommandsBuilder
    private var solaroRunMenu: some Commands {
        CommandMenu("Run") {
            Button {
                postSolaroMenuAction(.runPlay)
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .keyboardShortcut("r", modifiers: [.command])
            Button {
                postSolaroMenuAction(.runDebug)
            } label: {
                Label("Debug", systemImage: "ant.fill")
            }
            .keyboardShortcut("y", modifiers: [.command])
            Button {
                postSolaroMenuAction(.runTests)
            } label: {
                Label("Run Tests", systemImage: "checkmark.diamond")
            }
            .keyboardShortcut("u", modifiers: [.control, .command])
            Button {
                postSolaroMenuAction(.runStop)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .keyboardShortcut(".", modifiers: [.command])
            Divider()
            Button {
                postSolaroMenuAction(.runAutoLayout)
            } label: {
                Label("Auto Layout Canvas", systemImage: "rectangle.3.group")
            }
            Button {
                postSolaroMenuAction(.runExportCanvas)
            } label: {
                Label("Export Canvas as PNG…", systemImage: "square.and.arrow.up")
            }
            Button {
                postSolaroMenuAction(.runTimeTravel)
            } label: {
                Label("Time Travel…", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    /// Git menu — commit, blame, revert. Grouped together so the
    /// menu bar stays scannable.
    @CommandsBuilder
    private var solaroGitMenu: some Commands {
        CommandMenu("Git") {
            Button {
                postSolaroMenuAction(.gitCommit)
            } label: {
                Label("Commit Changes…", systemImage: "checkmark.seal")
            }
            .keyboardShortcut("k", modifiers: [.command])
            Divider()
            Button {
                postSolaroMenuAction(.gitBlame)
            } label: {
                Label("Blame Current File", systemImage: "person.crop.circle.badge.questionmark")
            }
            .keyboardShortcut("b", modifiers: [.control, .command])
            Button(role: .destructive) {
                postSolaroMenuAction(.gitRevertFile)
            } label: {
                Label("Revert Local Changes…", systemImage: "arrow.uturn.backward.circle")
            }
        }
    }

    /// AI menu — Ask panel, conversation reset.
    @CommandsBuilder
    private var solaroAIMenu: some Commands {
        CommandMenu("AI") {
            Button {
                postSolaroMenuAction(.aiOpenPanel)
            } label: {
                Label("Open Ask Panel", systemImage: "sparkles")
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            Button {
                postSolaroMenuAction(.aiReset)
            } label: {
                Label("Reset Conversation", systemImage: "arrow.counterclockwise")
            }
        }
    }
}

/// Per-window root. Owns the welcome ↔ workspace routing state so
/// SwiftUI hands each WindowGroup window its own copy. The result:
/// File → New Window (⌘N) opens a fresh welcome screen without
/// blowing away another window's open project.
struct RootView: View {
    let runtimeVersion: String
    @State private var workspace: WorkspaceState = RootView.initialWorkspace()
    @AppStorage(SolaroPrefs.theme.rawValue)
    private var themeRaw: String = SolaroTheme.dark.rawValue

    var body: some View {
        let theme = SolaroTheme(rawValue: themeRaw) ?? .dark
        ContentView(workspace: $workspace, runtimeVersion: runtimeVersion)
            .onOpenURL(perform: openURL)
            .preferredColorScheme(theme.colorScheme)
            .onAppear { SolaroTheme.apply(theme) }
            .onChange(of: themeRaw) { _, new in
                if let resolved = SolaroTheme(rawValue: new) {
                    SolaroTheme.apply(resolved)
                }
            }
            .task {
                // Pick up an ⌘-click "open in new window" hand-off
                // (#276). The welcome screen drops the project here
                // before asking SwiftUI for a new window; the first
                // RootView to appear after that consumes it.
                if case .welcome = workspace,
                   let pending = PendingNewWindowProject.take() {
                    workspace = .open(pending)
                }
            }
    }

    /// macOS Launch Services delivers `open -a Solaro.app <path>`
    /// invocations as an open-URL event rather than as argv. Two
    /// shapes land here now (#277):
    ///   * a directory URL — open it as the project root
    ///   * an .aro file URL — open the *containing* directory and
    ///     focus the file in the editor
    ///   * a solaro://… deep link — for future use, ignored for now
    private func openURL(_ url: URL) {
        // Deep links (solaro://foo) — keep a stub so they don't
        // crash. Real handlers can grow here later.
        if url.scheme == "solaro" { return }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return
        }
        if isDir.boolValue {
            workspace = .open(Project(rootPath: url))
            return
        }
        // File URL — open its enclosing directory as the project
        // and queue a deep link so the workspace can focus the
        // file once the project loads.
        let parent = url.deletingLastPathComponent()
        let project = Project(rootPath: parent)
        workspace = .open(project)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NotificationCenter.default.post(
                name: .solaroFocusFile, object: nil,
                userInfo: ["url": url]
            )
        }
    }

    /// Pull a project path out of CommandLine.arguments for the
    /// *first* window only — subsequent windows opened via ⌘N
    /// start on the welcome screen. argv reflects the launch
    /// invocation, which applies to the initial window.
    static func initialWorkspace() -> WorkspaceState {
        let candidates = CommandLine.arguments
            .dropFirst()
            .filter { !$0.hasPrefix("-") }
        guard let path = candidates.first else { return .welcome }
        let resolved = path == "." ? FileManager.default.currentDirectoryPath : path
        let url = URL(fileURLWithPath: resolved)
        var isDir: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
            isDir.boolValue
        else { return .welcome }
        // Only the very first RootView consumes argv; subsequent
        // windows reach this code path too, but argv is the same
        // for the whole process. We use a process-wide "consumed"
        // flag so window two onward starts at .welcome.
        if Self.argvConsumed { return .welcome }
        Self.argvConsumed = true
        return .open(Project(rootPath: url))
    }

    /// True once any RootView instance has claimed CommandLine.arguments.
    /// Synchronised because @main scenes can spin up multiple roots in
    /// parallel during onAppear, but in practice it's only racing with
    /// itself on app launch.
    private static var argvConsumed = false
}

/// Notification name used to ask a workspace to focus a file
/// after the project has finished loading (#277).
extension Notification.Name {
    static let solaroFocusFile = Notification.Name("solaroFocusFile")
    /// Posted from the View menu to ask the front workspace to
    /// open its bottom panel and switch to a specific pane. The
    /// `userInfo["tab"]` value is one of `"console"`, `"terminal"`,
    /// `"tests"` — matching `BottomTab.rawValue`.
    static let solaroShowBottomPanel = Notification.Name("solaroShowBottomPanel")
    /// Generic dispatch from menu bar items to the front workspace.
    /// `userInfo["id"]` carries one of `SolaroMenuAction.rawValue`.
    /// Centralising on a single notification keeps the listener
    /// short — the workspace switches on the action ID in one place
    /// rather than wiring 30+ named notifications.
    static let solaroMenuAction = Notification.Name("solaroMenuAction")
    /// Posted from the Run menu's "Auto Layout Canvas" item.
    /// `CenterPane` subscribes and wipes the saved positions in the
    /// project's layout store so the next graph build flows
    /// through `StackLayout.place()` defaults.
    static let solaroResetCanvasLayout = Notification.Name("solaroResetCanvasLayout")
    /// Posted by the sidebar's "+" button so the new-file sheet is
    /// hosted on the workspace root instead of inside the sidebar's
    /// NSHostingView. Presenting the sheet from inside the split
    /// view's child column triggered a constraint loop on macOS 26
    /// (`SplitViewChildController.hostingView(_:didUpdateMinSize:
    /// maxSize:)` rebroadcast every TextField keystroke to the
    /// split view, which re-invalidated layout, which re-rendered…).
    /// userInfo["dir"] carries the destination directory as a path
    /// string; nil/missing = "use the project root".
    static let solaroRequestNewFile = Notification.Name("solaroRequestNewFile")
}

/// Every menu-bar action the workspace knows how to route. New
/// menu items pick a raw value here and the workspace handler
/// gets a `default:` warning when it's added without a handler.
enum SolaroMenuAction: String {
    // File
    case fileRevealInFinder
    case fileCopyPath
    case fileRename
    case fileMoveToTrash
    case fileCloseTab
    // Edit
    case editFindInFile
    case editFindInProject
    case editFormatDocument
    case editRenameRefactor
    case editTriggerCompletion
    // View
    case viewToggleSidebar
    case viewToggleInspector
    case viewPaneMap
    case viewPaneCanvas
    case viewPaneText
    case viewPaneSplit
    case viewCommandPalette
    case viewQuickOpen
    case viewSymbolPalette
    // Navigate
    case navGoToDefinition
    case navHover
    case navNextTab
    case navPrevTab
    // Run
    case runPlay
    case runDebug
    case runTests
    case runStop
    case runAutoLayout
    case runExportCanvas
    case runTimeTravel
    // Git
    case gitCommit
    case gitBlame
    case gitRevertFile
    // AI
    case aiOpenPanel
    case aiReset
}

/// Post a menu action to the front workspace. Used by every
/// menu-bar item below.
func postSolaroMenuAction(_ action: SolaroMenuAction) {
    NotificationCenter.default.post(
        name: .solaroMenuAction,
        object: nil,
        userInfo: ["id": action.rawValue]
    )
}

/// Top-level routing between the welcome screen (no project open)
/// and the full workspace (project open).
///
/// Welcome is only shown when **no other window already has a project
/// open** — the canvas IDE is the meaningful entry point once you have
/// one running, and a second welcome window over it just gets in the
/// way. Per-window state still drives the actual switch; we only use
/// the global count to close redundant welcome windows.
struct ContentView: View {
    @Binding var workspace: WorkspaceState
    let runtimeVersion: String

    var body: some View {
        switch workspace {
        case .welcome:
            WelcomeView(runtimeVersion: runtimeVersion) { project in
                workspace = .open(project)
            }
            .onAppear { closeIfRedundantWelcome() }
        case .open(let project):
            WorkspaceView(project: project) {
                workspace = .welcome
            }
            .onAppear { OpenWorkspaceTracker.shared.increment() }
            .onDisappear { OpenWorkspaceTracker.shared.decrement() }
        }
    }

    /// If at least one other window already has a project workspace
    /// open, this window's welcome screen is a duplicate. Close it
    /// on next runloop tick so the user lands back on the live IDE
    /// rather than on the static welcome.
    private func closeIfRedundantWelcome() {
        guard OpenWorkspaceTracker.shared.count > 0 else { return }
        DispatchQueue.main.async {
            // Walk every window owned by the app and close the one
            // hosting *this* SwiftUI view. We can't grab `self`'s
            // hosting NSWindow directly from a struct View, but the
            // welcome screen is always the front-most window when it
            // just appeared.
            if let win = NSApp.windows.first(where: { $0.isVisible && $0.title == "Solaro" }) {
                win.close()
            } else {
                NSApp.keyWindow?.close()
            }
        }
    }
}

/// Process-wide count of windows whose `workspace` is `.open(...)`.
/// `ContentView` increments/decrements as project workspaces appear
/// and disappear; the welcome-screen routing checks this to decide
/// whether to render or auto-close.
@MainActor
final class OpenWorkspaceTracker {
    static let shared = OpenWorkspaceTracker()
    private init() {}
    private(set) var count: Int = 0
    func increment() { count += 1 }
    func decrement() { count = max(0, count - 1) }
}

// Per-window minimum size is enforced by `WorkspaceWindowSizer` in
// Workspace.swift — it adapts the floor to which panels are shown.

/// Undo command that picks the right UndoManager at click time:
/// the focused text-view's manager (so STTextView keeps character-
/// level undo) when a text field has focus, otherwise the front
/// workspace's UndoManager from `WorkspaceUndoRegistry.shared`.
struct SolaroUndoCommand: View {
    var body: some View {
        let registry = WorkspaceUndoRegistry.shared
        _ = registry.tick
        let textMgr = activeTextResponderUndoManager()
        let workspaceMgr = registry.current
        let active = textMgr ?? workspaceMgr
        return Button {
            active?.undo()
            registry.noteUndoChange()
        } label: {
            Text(active?.undoMenuItemTitle ?? "Undo")
        }
        .keyboardShortcut("z", modifiers: [.command])
        .disabled(active?.canUndo != true)
    }
}

struct SolaroRedoCommand: View {
    var body: some View {
        let registry = WorkspaceUndoRegistry.shared
        _ = registry.tick
        let textMgr = activeTextResponderUndoManager()
        let workspaceMgr = registry.current
        let active = textMgr ?? workspaceMgr
        return Button {
            active?.redo()
            registry.noteUndoChange()
        } label: {
            Text(active?.redoMenuItemTitle ?? "Redo")
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(active?.canRedo != true)
    }
}

/// Walks the front window's responder chain looking for an
/// `NSText` (the AppKit base for every text input — STTextView's
/// underlying view conforms). Returns its UndoManager so the Edit
/// menu can route ⌘Z to character-level undo while the editor has
/// focus. Returns nil when the focus is on the canvas or any other
/// non-text view, in which case the workspace UndoManager handles
/// it.
@MainActor
private func activeTextResponderUndoManager() -> UndoManager? {
    guard let window = NSApp.keyWindow,
          let first = window.firstResponder else { return nil }
    var responder: NSResponder? = first
    while let r = responder {
        if r is NSText {
            return r.undoManager
        }
        responder = r.nextResponder
    }
    return nil
}
