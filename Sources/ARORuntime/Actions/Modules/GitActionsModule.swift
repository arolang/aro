// ============================================================
// GitActionsModule.swift
// ARO Runtime - Git action module (ARO-0080)
// ============================================================

#if !os(Windows)

/// Git actions provide native version control from ARO code.
/// Uses libgit2 for local operations; shells out for push/pull.
public enum GitActionsModule: ActionModule {
    public static var actions: [any ActionImplementation.Type] {
        [
            StageAction.self,
            GitCommitAction.self,
            PullAction.self,
            PushAction.self,
            CloneAction.self,
            GitCheckoutAction.self,
            TagAction.self,
        ]
    }
}

#endif // !os(Windows)
