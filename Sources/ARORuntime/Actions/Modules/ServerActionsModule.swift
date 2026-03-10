// ============================================================
// ServerActionsModule.swift
// ARO Runtime - Server/service action module
// ============================================================

/// Server actions manage the lifecycle of long-running services
/// (HTTP server, file monitor, etc.).
public enum ServerActionsModule: ActionModule {
    public static var actions: [any ActionImplementation.Type] {
        [
            StartAction.self,
            StopAction.self,
            ListenAction.self,
            WaitForEventsAction.self,
            ScheduleAction.self,
            SleepAction.self,
        ]
    }
}
