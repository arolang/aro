# ARO-0044: Runtime Metrics

* Proposal: ARO-0044
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0004, ARO-0007

## Abstract

This proposal defines runtime metrics collection for feature set execution monitoring. The `<metrics>` magic variable provides access to execution counts, timing statistics, and success rates for all feature sets, with multiple output formats including Prometheus text format for integration with monitoring systems.

---

## 1. Motivation

### 1.1 The Need for Observability

Production ARO applications need observability into feature set execution:

```
+------------------+     +-----------------+     +------------------+
|  HTTP Request    | --> | Feature Set     | --> | Response         |
|  (listUsers)     |     | Execution       |     | (200 OK)         |
+------------------+     +-----------------+     +------------------+
                               |
                               v
                         +-------------+
                         | Metrics     |
                         | - count: 42 |
                         | - avg: 8ms  |
                         +-------------+
```

Without metrics, developers cannot answer:
- How many times has each feature set been called?
- What is the average execution time?
- Are there performance regressions?
- Which feature sets are failing?

### 1.2 Use Cases

1. **Performance Analysis**: Identify slow feature sets during development
2. **Production Monitoring**: Export metrics to Prometheus/Grafana
3. **Debugging**: Understand execution patterns
4. **Load Testing**: Measure throughput and latency under load

---

## 2. Syntax

### 2.1 The Metrics Magic Variable

The `<metrics>` variable is automatically available in all feature sets:

```aro
Log the <metrics> to the <console>.
```

### 2.2 Format Qualifiers

Use qualifiers to specify output format:

```aro
(* Different output formats *)
Log the <metrics: plain> to the <console>.       (* Context-aware full output *)
Log the <metrics: short> to the <console>.       (* One-liner summary *)
Log the <metrics: table> to the <console>.       (* ASCII table *)
Log the <metrics: prometheus> to the <console>.  (* Prometheus text format *)
```

| Qualifier | Description | Use Case |
|-----------|-------------|----------|
| `plain` | Context-aware detailed output | Development, debugging |
| `short` | Single-line summary | Quick status checks |
| `table` | ASCII table format | Terminal display |
| `prometheus` | Prometheus text format | Monitoring integration |

### 2.3 Default Behavior

Without a qualifier, `<metrics>` uses `plain` format:

```aro
(* These are equivalent *)
Log the <metrics> to the <console>.
Log the <metrics: plain> to the <console>.
```

---

## 3. Output Formats

### 3.1 Plain Format

Full context-aware output with all metrics:

```
Feature Set Metrics (3 total executions, uptime: 5.2s)

Application-Start (Entry Point)
  Executions: 1 (success: 1, failed: 0)
  Duration: avg=12.5ms, min=12.5ms, max=12.5ms

listUsers (User API)
  Executions: 2 (success: 2, failed: 0)
  Duration: avg=8.3ms, min=7.1ms, max=9.5ms
```

### 3.2 Short Format

Single-line summary for quick checks:

```
metrics: 3 executions, 2 featuresets, avg=10.4ms, uptime=5.2s
```

### 3.3 Table Format

ASCII table for terminal display:

```
+-------------------+-------+---------+--------+---------+---------+
| Feature Set       | Count | Success | Failed | Avg(ms) | Max(ms) |
+-------------------+-------+---------+--------+---------+---------+
| Application-Start |     1 |       1 |      0 |   12.50 |   12.50 |
| listUsers         |     2 |       2 |      0 |    8.30 |    9.50 |
+-------------------+-------+---------+--------+---------+---------+
| TOTAL             |     3 |       3 |      0 |   10.40 |   12.50 |
+-------------------+-------+---------+--------+---------+---------+
```

### 3.4 Prometheus Format

Standard Prometheus text format for monitoring integration:

```
# HELP aro_featureset_executions_total Total number of feature set executions
# TYPE aro_featureset_executions_total counter
aro_featureset_executions_total{featureset="Application-Start",activity="Entry Point"} 1
aro_featureset_executions_total{featureset="listUsers",activity="User API"} 2

# HELP aro_featureset_success_total Total successful executions
# TYPE aro_featureset_success_total counter
aro_featureset_success_total{featureset="Application-Start",activity="Entry Point"} 1
aro_featureset_success_total{featureset="listUsers",activity="User API"} 2

# HELP aro_featureset_failures_total Total failed executions
# TYPE aro_featureset_failures_total counter
aro_featureset_failures_total{featureset="Application-Start",activity="Entry Point"} 0
aro_featureset_failures_total{featureset="listUsers",activity="User API"} 0

# HELP aro_featureset_duration_ms_avg Average execution duration in milliseconds
# TYPE aro_featureset_duration_ms_avg gauge
aro_featureset_duration_ms_avg{featureset="Application-Start",activity="Entry Point"} 12.5
aro_featureset_duration_ms_avg{featureset="listUsers",activity="User API"} 8.3

# HELP aro_featureset_duration_ms_max Maximum execution duration in milliseconds
# TYPE aro_featureset_duration_ms_max gauge
aro_featureset_duration_ms_max{featureset="Application-Start",activity="Entry Point"} 12.5
aro_featureset_duration_ms_max{featureset="listUsers",activity="User API"} 9.5

# HELP aro_application_uptime_seconds Application uptime in seconds
# TYPE aro_application_uptime_seconds gauge
aro_application_uptime_seconds 5.2
```

---

## 4. Collected Metrics

### 4.1 Per-Feature Set Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `executionCount` | Counter | Total number of executions |
| `successCount` | Counter | Successful executions |
| `failureCount` | Counter | Failed executions |
| `totalDurationMs` | Sum | Cumulative execution time |
| `minDurationMs` | Gauge | Fastest execution |
| `maxDurationMs` | Gauge | Slowest execution |
| `averageDurationMs` | Computed | `totalDurationMs / executionCount` |
| `successRate` | Computed | `successCount / executionCount * 100` |

### 4.2 Global Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `totalExecutions` | Counter | Sum of all feature set executions |
| `applicationStartTime` | Timestamp | When the application started |
| `uptimeSeconds` | Computed | Current time - start time |

### 4.3 Labels

Each metric includes identifying labels:

| Label | Description | Example |
|-------|-------------|---------|
| `featureset` | Feature set name | `listUsers` |
| `activity` | Business activity | `User API` |

---

## 5. Implementation

### 5.1 Architecture

```
+-------------------+     +--------------------+     +-------------------+
| FeatureSetExecutor| --> | FeatureSet         | --> | MetricsCollector  |
|                   |     | CompletedEvent     |     | (Actor)           |
+-------------------+     +--------------------+     +-------------------+
                                                            |
                          +--------------------+            |
                          | EventBus           | <----------+
                          | (subscription)     |
                          +--------------------+

                          +--------------------+
                          | RuntimeContext     |
                          | resolveAny()       | --> returns MetricsSnapshot
                          +--------------------+

                          +--------------------+
                          | LogAction          |
                          | (format detection) | --> MetricsFormatter
                          +--------------------+
```

### 5.2 MetricsCollector

A Swift actor that subscribes to `FeatureSetCompletedEvent`:

```swift
public actor MetricsCollector {
    public static let shared = MetricsCollector()

    private var metrics: [String: FeatureSetMetrics] = [:]
    private let startTime = Date()

    public func start(eventBus: EventBus) {
        eventBus.subscribe(to: FeatureSetCompletedEvent.self) { event in
            await self.recordExecution(event)
        }
    }

    public func snapshot() -> MetricsSnapshot {
        MetricsSnapshot(
            featureSets: Array(metrics.values),
            collectedAt: Date(),
            applicationStartTime: startTime,
            totalExecutions: metrics.values.reduce(0) { $0 + $1.executionCount }
        )
    }
}
```

### 5.3 Magic Variable Access

The `<metrics>` variable is resolved in `RuntimeContext.resolveAny()`:

```swift
public func resolveAny(_ name: String) -> (any Sendable)? {
    // Magic variable: <metrics> returns current execution metrics
    if name == "metrics" {
        return MetricsCollector.shared.snapshot()
    }
    // ... other magic variables
}
```

### 5.4 Format Detection in LogAction

The Log action detects metrics format qualifiers:

```swift
if result.base == "metrics" {
    if let metrics = context.resolveAny("metrics") as? MetricsSnapshot {
        let format = result.specifiers.first ?? "plain"
        message = MetricsFormatter.format(metrics, as: format, context: context.outputContext)
    }
}
```

---

## 6. Examples

### 6.1 Basic Usage

```aro
(Application-Start: Metrics Demo) {
    Log "Starting application..." to the <console>.

    (* Log metrics at startup - will show 1 execution *)
    Log the <metrics: short> to the <console>.

    Return an <OK: status> for the <startup>.
}
```

### 6.2 Prometheus Endpoint

```aro
(getMetrics: Monitoring API) {
    Return an <OK: status> with <metrics: prometheus>.
}
```

OpenAPI contract:
```yaml
paths:
  /metrics:
    get:
      operationId: getMetrics
      responses:
        200:
          description: Prometheus metrics
          content:
            text/plain:
              schema:
                type: string
```

### 6.3 Periodic Logging

```aro
(Log Metrics: Timer Handler) {
    Log the <metrics: table> to the <console>.
    Return an <OK: status> for the <logging>.
}
```

### 6.4 Graceful Shutdown

```aro
(Application-End: Success) {
    Log "Final metrics:" to the <console>.
    Log the <metrics: plain> to the <console>.
    Return an <OK: status> for the <shutdown>.
}
```

---

## 7. Design Decisions

### 7.1 Actor-Based Collection

Metrics collection uses a Swift actor for thread safety, as multiple feature sets may execute concurrently.

### 7.2 No Reset Capability

Metrics accumulate for the application lifetime. There is no `<Reset> the <metrics>` action. Rationale:
- Prometheus expects monotonically increasing counters
- Simplifies implementation
- Reset functionality adds complexity with minimal benefit

### 7.3 Business Activity Labels

Metrics include `businessActivity` labels for better organization in Prometheus dashboards and grouping related feature sets.

### 7.4 Qualifier-Based Formatting

Format selection via qualifiers (`<metrics: prometheus>`) rather than separate variables (`<prometheus-metrics>`) is consistent with ARO's qualifier system and more discoverable.

---

## 8. Thread Safety

The `MetricsCollector` actor ensures thread-safe access:

1. **Recording**: Event handler updates metrics atomically
2. **Reading**: `snapshot()` returns an immutable copy
3. **No locks needed**: Actor isolation handles synchronization

```
Thread A (HTTP Request)          Thread B (Event Handler)
         |                                |
         v                                v
   +-----------+                   +-----------+
   | execute() |                   | execute() |
   +-----------+                   +-----------+
         |                                |
         v                                v
   +------------------------------------------+
   |        MetricsCollector (Actor)          |
   |  recordExecution() - serialized access   |
   +------------------------------------------+
```

---

## Summary

| Aspect | Description |
|--------|-------------|
| **Variable** | `<metrics>` magic variable |
| **Formats** | plain, short, table, prometheus |
| **Collected** | Counts, timing (avg/min/max), success rate |
| **Labels** | featureset, activity (business activity) |
| **Thread Safety** | Actor-based collection |
| **Lifetime** | Metrics persist until application exit |

---

## References

- `Sources/ARORuntime/Metrics/MetricsCollector.swift` - Actor-based metrics collection
- `Sources/ARORuntime/Metrics/MetricsFormatter.swift` - Output formatters
- `Sources/ARORuntime/Core/RuntimeContext.swift` - Magic variable resolution
- `Examples/MetricsDemo/` - Metrics usage examples
- ARO-0001: Language Fundamentals - Core syntax
- ARO-0004: Actions - Log action
- ARO-0007: Events & Reactive - EventBus subscription
- ARO-0031: Context-Aware Formatting - Output context
