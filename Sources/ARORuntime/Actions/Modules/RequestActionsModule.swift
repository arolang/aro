// ============================================================
// RequestActionsModule.swift
// ARO Runtime - REQUEST action module
// ============================================================

/// REQUEST actions bring data from external sources into the feature set context
/// (External → Internal data flow).
public enum RequestActionsModule: ActionModule {
    public static var actions: [any ActionImplementation.Type] {
        [
            ExtractAction.self,
            RetrieveAction.self,
            ReceiveAction.self,
            RequestAction.self,
            ReadAction.self,
            StreamAction.self,
        ]
    }
}
