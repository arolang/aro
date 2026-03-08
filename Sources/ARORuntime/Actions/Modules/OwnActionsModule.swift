// ============================================================
// OwnActionsModule.swift
// ARO Runtime - OWN action module
// ============================================================

/// OWN actions transform data already present in the feature set context
/// (Internal → Internal data flow).
public enum OwnActionsModule: ActionModule {
    public static var actions: [any ActionImplementation.Type] {
        [
            ComputeAction.self,
            ValidateAction.self,
            CompareAction.self,
            TransformAction.self,
            CreateAction.self,
            UpdateAction.self,
            SortAction.self,
            SplitAction.self,
            MergeAction.self,
            DeleteAction.self,
            ParseHtmlAction.self,
        ]
    }
}
