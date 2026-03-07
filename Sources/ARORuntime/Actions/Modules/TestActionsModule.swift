// ============================================================
// TestActionsModule.swift
// ARO Runtime - Testing action module (ARO-0015)
// ============================================================

/// Test actions implement the Given/When/Then/Assert BDD testing vocabulary.
public enum TestActionsModule: ActionModule {
    public static var actions: [any ActionImplementation.Type] {
        [
            GivenAction.self,
            WhenAction.self,
            ThenAction.self,
            AssertAction.self,
        ]
    }
}
