// ============================================================
// DataPipelineActionsModule.swift
// ARO Runtime - Data pipeline action module (ARO-0018)
// ============================================================

/// Data pipeline actions transform collections using functional operations.
public enum DataPipelineActionsModule: ActionModule {
    public static var actions: [any ActionImplementation.Type] {
        [
            MapAction.self,
            ReduceAction.self,
            FilterAction.self,
        ]
    }
}
