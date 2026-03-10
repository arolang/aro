// ============================================================
// SocketActionsModule.swift
// ARO Runtime - Socket action module (ARO-0024)
// ============================================================

/// Socket actions manage TCP connections and bidirectional messaging.
public enum SocketActionsModule: ActionModule {
    public static var actions: [any ActionImplementation.Type] {
        [
            ConnectAction.self,
            BroadcastAction.self,
            CloseAction.self,
        ]
    }
}
