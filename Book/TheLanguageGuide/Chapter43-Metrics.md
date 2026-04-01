# Chapter 43: Runtime Metrics

ARO automatically tracks execution metrics for all feature sets. The `<metrics>` magic variable provides access to execution counts, timing statistics, and success rates.

## The Metrics Variable

Access metrics like any variable:

```aro
Log the <metrics> to the <console>.
```

This outputs all collected metrics in a readable format.

## Format Qualifiers

Use qualifiers to control output format:

```aro
Log the <metrics: plain> to the <console>.       (* Full details *)
Log the <metrics: short> to the <console>.       (* One-liner *)
Log the <metrics: table> to the <console>.       (* ASCII table *)
Log the <metrics: prometheus> to the <console>.  (* For monitoring *)
```

| Qualifier | Output |
|-----------|--------|
| `plain` | Detailed multi-line output (default) |
| `short` | Single-line summary |
| `table` | ASCII table format |
| `prometheus` | Prometheus text format |

## Output Examples

### Plain Format

The default format shows all metrics with context:

```
Feature Set Metrics (3 total executions, uptime: 5.2s)

Application-Start (Entry Point)
  Executions: 1 (success: 1, failed: 0)
  Duration: avg=12.5ms, min=12.5ms, max=12.5ms

listUsers (User API)
  Executions: 2 (success: 2, failed: 0)
  Duration: avg=8.3ms, min=7.1ms, max=9.5ms
```

### Short Format

A quick summary for status checks:

```
metrics: 3 executions, 2 featuresets, avg=10.4ms, uptime=5.2s
```

### Table Format

Terminal-friendly ASCII table:

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

### Prometheus Format

Standard Prometheus text format for monitoring integration:

```
# HELP aro_featureset_executions_total Total number of feature set executions
# TYPE aro_featureset_executions_total counter
aro_featureset_executions_total{featureset="listUsers",activity="User API"} 2

# HELP aro_featureset_duration_ms_avg Average execution duration in milliseconds
# TYPE aro_featureset_duration_ms_avg gauge
aro_featureset_duration_ms_avg{featureset="listUsers",activity="User API"} 8.3
```

## Collected Metrics

ARO tracks the following for each feature set:

| Metric | Description |
|--------|-------------|
| **Execution Count** | Total number of times the feature set ran |
| **Success Count** | How many executions completed successfully |
| **Failure Count** | How many executions threw errors |
| **Average Duration** | Mean execution time in milliseconds |
| **Min Duration** | Fastest execution |
| **Max Duration** | Slowest execution |

Plus global metrics:

| Metric | Description |
|--------|-------------|
| **Total Executions** | Sum across all feature sets |
| **Uptime** | Time since application started |

## Practical Examples

### Development Debugging

Print metrics at shutdown to see what ran:

```aro
(Application-End: Success) {
    Log "=== Final Metrics ===" to the <console>.
    Log the <metrics: table> to the <console>.
    Return an <OK: status> for the <shutdown>.
}
```

### Quick Status Check

A one-liner during execution:

```aro
Log the <metrics: short> to the <console>.
```

Output:
```
metrics: 15 executions, 4 featuresets, avg=12.3ms, uptime=30.5s
```

### Prometheus Endpoint

Expose metrics for monitoring systems:

```aro
(getMetrics: Monitoring API) {
    Return an <OK: status> with <metrics: prometheus>.
}
```

With OpenAPI contract:

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

Now Prometheus can scrape `http://your-app/metrics`.

### Performance Analysis

Compare feature set performance:

```aro
(analyzePerformance: Admin API) {
    Log "Performance Analysis:" to the <console>.
    Log the <metrics: table> to the <console>.
    Return an <OK: status> with <metrics: plain>.
}
```

<div style="text-align: center; margin: 2em 0;">
<svg width="560" height="130" viewBox="0 0 560 130" xmlns="http://www.w3.org/2000/svg" font-family="sans-serif">
  <defs>
    <marker id="arrowM" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#374151"/>
    </marker>
    <marker id="arrowMdash" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#9ca3af"/>
    </marker>
  </defs>

  <!-- Feature Set box -->
  <rect x="10" y="30" width="120" height="60" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="70" y="56" text-anchor="middle" font-size="11" font-weight="bold" fill="#4338ca">Feature Set</text>
  <text x="70" y="72" text-anchor="middle" font-size="9" fill="#4338ca">statements execute</text>
  <text x="70" y="84" text-anchor="middle" font-size="9" fill="#4338ca">counters increment</text>

  <!-- Arrow 1 -->
  <line x1="130" y1="60" x2="158" y2="60" stroke="#374151" stroke-width="1.5" marker-end="url(#arrowM)"/>

  <!-- Runtime Metrics box -->
  <rect x="160" y="30" width="120" height="60" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="220" y="56" text-anchor="middle" font-size="11" font-weight="bold" fill="#92400e">Runtime Metrics</text>
  <text x="220" y="72" text-anchor="middle" font-size="9" fill="#92400e">counts, timings</text>
  <text x="220" y="84" text-anchor="middle" font-size="9" fill="#92400e">stored in actor</text>

  <!-- Arrow 2 -->
  <line x1="280" y1="60" x2="308" y2="60" stroke="#374151" stroke-width="1.5" marker-end="url(#arrowM)"/>

  <!-- Collect box -->
  <rect x="310" y="30" width="130" height="60" rx="4" fill="#d1fae5" stroke="#22c55e" stroke-width="2"/>
  <text x="375" y="52" text-anchor="middle" font-size="11" font-weight="bold" fill="#166534">Collect</text>
  <text x="375" y="66" text-anchor="middle" font-size="9" fill="#166534">Collect the</text>
  <text x="375" y="78" text-anchor="middle" font-size="9" fill="#166534">&lt;metrics&gt;</text>

  <!-- Arrow 3 (dashed) -->
  <line x1="440" y1="60" x2="468" y2="60" stroke="#9ca3af" stroke-width="1.5" stroke-dasharray="4,2" marker-end="url(#arrowMdash)"/>

  <!-- Response/Prometheus box (dashed border) -->
  <rect x="470" y="20" width="80" height="80" rx="4" fill="#1f2937" stroke="#1f2937" stroke-width="2" stroke-dasharray="4,2"/>
  <text x="510" y="52" text-anchor="middle" font-size="10" fill="#ffffff">Response /</text>
  <text x="510" y="66" text-anchor="middle" font-size="10" fill="#ffffff">Prometheus</text>
  <text x="510" y="80" text-anchor="middle" font-size="9" fill="#9ca3af">/metrics</text>

  <!-- Labels below -->
  <text x="70" y="118" text-anchor="middle" font-size="9" fill="#374151">automatic</text>
  <text x="220" y="118" text-anchor="middle" font-size="9" fill="#374151">thread-safe</text>
  <text x="375" y="118" text-anchor="middle" font-size="9" fill="#374151">on-demand snapshot</text>
  <text x="510" y="118" text-anchor="middle" font-size="9" fill="#9ca3af">export</text>
</svg>
</div>

## How It Works

ARO automatically collects metrics without any configuration:

1. **Event Subscription**: The runtime subscribes to `FeatureSetCompletedEvent`
2. **Automatic Recording**: Each execution updates counts and timing
3. **Thread-Safe Storage**: An actor ensures safe concurrent access
4. **On-Demand Access**: `<metrics>` returns a snapshot of current state

You don't need to instrument your code. Metrics collection is built into the runtime.

## Integration with Context-Aware Formatting

The `plain` format respects the output context (see Chapter 40):

| Context | Plain Format Behavior |
|---------|----------------------|
| Human | Readable multi-line output |
| Machine | JSON structure |
| Developer | Detailed with type annotations |

Other formats (`short`, `table`, `prometheus`) are context-independent.

## Limitations

- **No Reset**: Metrics accumulate for the application lifetime
- **In-Memory Only**: Metrics are not persisted across restarts
- **Per-Application**: No cross-application metric aggregation

For production monitoring, export to Prometheus and use Grafana for dashboards, alerting, and historical analysis.

---

*Previous: Chapter 42 — Date and Time*
