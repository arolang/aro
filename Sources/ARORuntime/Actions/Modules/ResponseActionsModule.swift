// ============================================================
// ResponseActionsModule.swift
// ARO Runtime - RESPONSE and EXPORT action module
// ============================================================

/// RESPONSE actions send data out of the feature set to the caller (terminating
/// execution), and EXPORT actions persist or broadcast data without terminating.
public enum ResponseActionsModule: ActionModule {
    public static var actions: [any ActionImplementation.Type] {
        [
            // RESPONSE: terminate the execution path
            ReturnAction.self,
            ThrowAction.self,

            // EXPORT: side-effects that allow execution to continue
            SendAction.self,
            LogAction.self,
            StoreAction.self,
            WriteAction.self,
            NotifyAction.self,
            PublishAction.self,
            EmitAction.self,
        ]
    }
}
