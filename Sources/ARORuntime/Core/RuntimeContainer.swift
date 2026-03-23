// ============================================================
// RuntimeContainer.swift
// ARO Runtime - Dependency Injection Container
// ============================================================

import Foundation

// MARK: - RuntimeContainer

/// Lightweight DI container that groups all runtime-level services.
///
/// `RuntimeContainer` is the single source of truth for infrastructure
/// services used by actions. Production code uses `RuntimeContainer.default`
/// (backed by all existing singletons). Tests construct a fresh, isolated
/// container to prevent cross-test state leakage.
///
/// Usage in actions:
/// ```swift
/// let storage = context.service(RepositoryStorageService.self)
///     ?? context.container.repositoryStorage
/// let result = try context.container.qualifierRegistry.resolve(name, value: input)
/// await context.container.eventBus.publishAndTrack(event)
/// ```
///
/// Usage in tests:
/// ```swift
/// let bus = EventBus()
/// let storage = InMemoryRepositoryStorage()
/// let container = RuntimeContainer(eventBus: bus, repositoryStorage: storage)
/// let context = RuntimeContext(featureSetName: "Test", container: container)
/// // — no shared state touched —
/// ```
public final class RuntimeContainer: @unchecked Sendable {

    // MARK: - Services

    /// Event bus for publishing and subscribing to domain events.
    public let eventBus: EventBus

    /// Registry mapping action verbs to their implementations.
    public let actionRegistry: ActionRegistry

    /// Repository storage service for in-memory data persistence.
    public let repositoryStorage: any RepositoryStorageService

    /// Registry for plugin-provided qualifier transformations.
    public let qualifierRegistry: QualifierRegistry

    /// Registry for external services (HTTP client, etc.).
    public let externalServices: ExternalServiceRegistry

    /// Storage for CLI / command-line parameters.
    public let parameterStorage: ParameterStorage

    /// Collector for execution metrics and timings.
    public let metricsCollector: MetricsCollector

    // MARK: - Default (singleton-backed) container

    /// The default container backed by all existing shared singletons.
    /// This is the container used in production; it wraps the same global
    /// instances that existing code references directly.
    public static let `default` = RuntimeContainer()

    // MARK: - Initialization

    /// Create a container.
    ///
    /// All parameters default to their respective shared singletons, so
    /// `RuntimeContainer()` is equivalent to using each `.shared` reference
    /// individually. To get test isolation, pass fresh instances explicitly:
    ///
    /// ```swift
    /// let container = RuntimeContainer(
    ///     eventBus: EventBus(),
    ///     repositoryStorage: InMemoryRepositoryStorage()
    /// )
    /// ```
    public init(
        eventBus: EventBus = .shared,
        actionRegistry: ActionRegistry = .shared,
        repositoryStorage: any RepositoryStorageService = InMemoryRepositoryStorage.shared,
        qualifierRegistry: QualifierRegistry = .shared,
        externalServices: ExternalServiceRegistry = .shared,
        parameterStorage: ParameterStorage = .shared,
        metricsCollector: MetricsCollector = .shared
    ) {
        self.eventBus = eventBus
        self.actionRegistry = actionRegistry
        self.repositoryStorage = repositoryStorage
        self.qualifierRegistry = qualifierRegistry
        self.externalServices = externalServices
        self.parameterStorage = parameterStorage
        self.metricsCollector = metricsCollector
    }
}
