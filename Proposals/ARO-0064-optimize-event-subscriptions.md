# ARO-0064: Optimize Event Subscription Matching

* Proposal: ARO-0064
* Author: ARO Language Team
* Status: **Implemented**
* Related Issues: GitLab #112

## Abstract

Optimize EventBus subscription matching from O(n) linear scan to O(1) indexed lookup by organizing subscriptions by event type.

## Problem

Current implementation filters ALL subscriptions for every event publish:

```swift
private func getMatchingSubscriptions(for eventType: String) -> [Subscription] {
    withLock {
        subscriptions.filter { $0.eventType == eventType || $0.eventType == "*" }
    }
}
```

With many subscriptions, this becomes inefficient:
- 100 feature sets with domain event handlers
- 50 repository observers
- 20 file event handlers
- **Total**: 170 subscriptions × every event = O(170) filter operation

## Solution

### Indexed Data Structure

```swift
/// Subscriptions indexed by event type for O(1) lookup
private var subscriptionsByType: [String: [Subscription]] = [:]

/// Wildcard subscribers (notified for all events)
private var wildcardSubscriptions: [Subscription] = []
```

### Optimized Lookup

```swift
private func getMatchingSubscriptions(for eventType: String) -> [Subscription] {
    withLock {
        // O(1) dictionary lookup + wildcards
        let typeSubscriptions = subscriptionsByType[eventType] ?? []
        return typeSubscriptions + wildcardSubscriptions
    }
}
```

### Updated Registration

```swift
public func subscribe(to eventType: String, handler: EventHandler) -> UUID {
    let subscription = Subscription(id: UUID(), eventType: eventType, handler: handler)

    withLock {
        if eventType == "*" {
            wildcardSubscriptions.append(subscription)
        } else {
            subscriptionsByType[eventType, default: []].append(subscription)
        }
    }

    return subscription.id
}
```

### Unsubscribe Update

```swift
public func unsubscribe(_ id: UUID) {
    withLock {
        // Remove from wildcard subscriptions
        wildcardSubscriptions.removeAll { $0.id == id }

        // Remove from type-specific subscriptions
        for key in subscriptionsByType.keys {
            subscriptionsByType[key]?.removeAll { $0.id == id }
            if subscriptionsByType[key]?.isEmpty == true {
                subscriptionsByType.removeValue(forKey: key)
            }
        }
    }
}
```

## Performance Impact

| Subscriptions | Before (filter) | After (indexed) | Improvement |
|---------------|-----------------|-----------------|-------------|
| 10            | O(10)           | O(1)            | 10x faster  |
| 100           | O(100)          | O(1)            | 100x faster |
| 1000          | O(1000)         | O(1)            | 1000x faster|

## Trade-offs

**Benefits:**
- O(1) lookup for matching subscriptions
- Scales to thousands of subscriptions
- No behavior changes, just performance

**Costs:**
- Slightly more memory (dictionary overhead)
- Unsubscribe is now O(k) where k = number of event types (typically small)
- More complex data structure

## Migration

No API changes required. Existing code continues to work unchanged.

Fixes GitLab #112
