# ARO-0054: Execution Engine Refactor

* Proposal: ARO-0054
* Author: ARO Language Team
* Status: **Implemented**
* Related Issues: GitLab #106

## Abstract

Eliminate code duplication in ExecutionEngine by introducing a generic event handler execution pattern. This refactoring removes ~150 lines of duplicated code across three static handler methods while maintaining identical runtime behavior.

## Motivation

The ExecutionEngine has three nearly identical static methods for executing event handlers:
- `executeDomainEventHandlerStatic` (lines 469-523)
- `executeRepositoryObserverStatic` (lines 526-589)
- `executeStateObserverStatic` (lines 1066-1129)

Each method follows the exact same pattern:

1. Create a child RuntimeContext
2. Bind event-specific data to the context
3. Register services from the base context
4. Create a FeatureSetExecutor
5. Execute the feature set
6. Handle errors by publishing ErrorOccurredEvent

**The only difference** is how event data is extracted and bound to the context (step 2).

This duplication creates maintenance issues:
- Bug fixes must be applied to all three methods
- Inconsistencies can arise between handlers
- Adding new handler types requires copying all the boilerplate

## Proposed Solution

Introduce a generic `executeHandler<E: RuntimeEvent>()` method that accepts a closure for event-specific data binding:

```swift
private static func executeHandler<E: RuntimeEvent>(
    _ analyzedFS: AnalyzedFeatureSet,
    baseContext: RuntimeContext,
    event: E,
    actionRegistry: ActionRegistry,
    eventBus: EventBus,
    globalSymbols: GlobalSymbolStorage,
    services: ServiceRegistry,
    bindEventData: @Sendable (RuntimeContext, E) -> Void
) async {
    // 1. Create child context (shared)
    let handlerContext = RuntimeContext(...)

    // 2. Bind event-specific data (customizable via closure)
    bindEventData(handlerContext, event)

    // 3-6. Common logic (shared)
    await services.registerAll(in: handlerContext)
    let executor = FeatureSetExecutor(...)
    do {
        _ = try await executor.execute(analyzedFS, context: handlerContext)
    } catch {
        eventBus.publish(ErrorOccurredEvent(...))
    }
}
```

### Usage

The three specialized handlers become thin wrappers:

```swift
private static func executeDomainEventHandlerStatic(...) async {
    await executeHandler(...) { context, event in
        context.bind("event", value: event.payload)
        for (key, value) in event.payload {
            context.bind("event:\(key)", value: value)
        }
    }
}

private static func executeRepositoryObserverStatic(...) async {
    await executeHandler(...) { context, event in
        var eventPayload: [String: any Sendable] = [
            "repositoryName": event.repositoryName,
            "changeType": event.changeType.rawValue,
            "timestamp": event.timestamp
        ]
        // ... build and bind payload
    }
}
```

## Benefits

1. **Reduced Duplication**: Eliminates ~150 lines of duplicated code
2. **Single Source of Truth**: Bug fixes and improvements in one place
3. **Consistency**: All handlers guaranteed to have identical error handling
4. **Type Safety**: Generic constraint ensures proper event types
5. **Flexibility**: Closure allows event-specific customization
6. **No Behavior Change**: Runtime behavior remains 100% identical

## Implementation

### Files Modified
- `Sources/ARORuntime/Core/ExecutionEngine.swift`

### Changes
1. Add generic `executeHandler<E>()` method (lines ~469)
2. Refactor `executeDomainEventHandlerStatic()` to use generic method
3. Refactor `executeRepositoryObserverStatic()` to use generic method
4. Refactor `executeStateObserverStatic()` to use generic method

## Backward Compatibility

✅ **Fully backward compatible**
- No changes to public API
- No changes to event handler registration
- No changes to event dispatching
- Identical runtime behavior
- All tests pass without modification

## Testing Strategy

1. All existing tests must pass (no behavioral changes)
2. Run full test suite: `swift test`
3. Run example verification: `./test-examples.pl`
4. Run REPL tests: `./test_repl.pl`

## Implementation Notes

### Actor Isolation

The generic handler is a static method (not actor-isolated) to avoid actor reentrancy deadlock. This pattern is already established in the current implementation.

### Closure Sendability

The `bindEventData` closure is marked `@Sendable` to work with Swift's concurrency model. This is handled correctly by the compiler.

### Performance

No performance impact. The closure call adds negligible overhead compared to the feature set execution.

## Conclusion

The generic handler pattern provides a clean, type-safe solution that eliminates code duplication while maintaining all existing behavior and performance. This is a low-risk refactoring with significant maintainability benefits.
