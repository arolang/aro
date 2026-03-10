// ============================================================
// TerminalActionsModule.swift
// ARO Runtime - Terminal/TUI action module (ARO-0052)
// ============================================================

/// Terminal actions drive interactive TUI applications: prompts, selection
/// menus, screen rendering, and display management.
public enum TerminalActionsModule: ActionModule {
    public static var actions: [any ActionImplementation.Type] {
        [
            PromptAction.self,
            SelectAction.self,
            ClearAction.self,
            ShowAction.self,
            RenderAction.self,
            RepaintAction.self,
        ]
    }
}
