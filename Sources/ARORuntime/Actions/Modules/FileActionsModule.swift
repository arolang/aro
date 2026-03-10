// ============================================================
// FileActionsModule.swift
// ARO Runtime - File operation action module (ARO-0036)
// ============================================================

/// File actions provide extended file-system operations beyond basic read/write.
public enum FileActionsModule: ActionModule {
    public static var actions: [any ActionImplementation.Type] {
        [
            ListAction.self,
            StatAction.self,
            ExistsAction.self,
            MakeAction.self,
            CopyAction.self,
            MoveAction.self,
            AppendAction.self,
        ]
    }
}
