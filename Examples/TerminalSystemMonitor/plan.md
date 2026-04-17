# Build a terminal system monitor with live metrics

Create an ARO application that displays real-time system metrics (CPU, memory, disk) in the terminal, refreshing periodically.

- `openapi.yaml` -- No HTTP paths (`paths: {}`), but define SystemMetrics, MemoryMetrics, and DiskMetrics schemas for typed extraction.

- `main.aro` -- Three feature sets:
  1. `Application-Start: System Monitor` -- Clear the screen and cursor. Retrieve initial system metrics with `Retrieve the <stats: SystemMetrics> from the <system>`. Render the display using `Transform the <display> from the <template: monitor.screen>` and `Render the <display> to the <console>`. Schedule periodic updates with `Schedule the <metrics-tick> with 2 seconds`. Use Keepalive.
  2. `Application-End: Success` -- Show the cursor again.
  3. `Collect Metrics: metrics-tick Handler` -- Retrieve fresh system metrics, transform and render the display template. The section compositor diffs against the shadow buffer and only redraws changed lines.
