// ============================================================
// DependencyServiceRegistry.swift
// ARO Runtime - Dependency injection registry (the `ServiceRegistry` actor)
//
// Named for the file it lives in rather than the type it holds: the runtime
// already has a `Services/ServiceRegistry.swift` for external `AROService`
// implementations, and SwiftPM rejects two source files of the same name.
// ============================================================

import Foundation

// MARK: - Service Registry

/// Registry for dependency injection.
/// Converted to actor for Swift 6.2 concurrency safety (Issue #2).
public actor ServiceRegistry {
    private var services: [ObjectIdentifier: any Sendable] = [:]

    public init() {}

    /// Register a service
    public func register<S: Sendable>(_ service: S) {
        services[ObjectIdentifier(S.self)] = service
    }

    /// Resolve a service
    public func resolve<S>(_ type: S.Type) -> S? {
        services[ObjectIdentifier(type)] as? S
    }

    /// Register all services in a context
    public func registerAll(in context: ExecutionContext) {
        for (typeId, service) in services {
            // Preserve type ID to avoid type erasure
            context.registerWithTypeId(typeId, service: service)
        }
    }
}
