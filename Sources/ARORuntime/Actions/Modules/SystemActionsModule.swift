// ============================================================
// SystemActionsModule.swift
// ARO Runtime - System and utility action module
// ============================================================

/// System actions handle scheduling, state transitions, external service calls,
/// shell execution, template inclusion, and application lifecycle utilities.
public enum SystemActionsModule: ActionModule {
    public static var actions: [any ActionImplementation.Type] {
        [
            // Lifecycle
            WaitForEventsAction.self,
            ScheduleAction.self,
            AcceptAction.self,

            // External integration (ARO-0016)
            CallAction.self,

            // Shell execution (ARO-0033)
            ExecuteAction.self,

            // Template rendering (ARO-0050)
            IncludeAction.self,
        ]
    }
}
