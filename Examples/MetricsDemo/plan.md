# Build a runtime metrics demo

Create a single-file ARO application that demonstrates runtime metrics tracking with multiple output formats.

In `main.aro`, define three feature sets:

1. `Application-Start: Metrics Demo` -- Create a list of items [1, 2, 3]. Use `parallel for each <item> in <items>` to emit `<ProcessItem: event>` for each item in parallel.

2. `Process Item: ProcessItem Handler` -- Extract the value from the event and log "Processing item: ${value}".

3. `Application-End: Success` -- Display metrics in four formats:
   - `Log the <metrics: short> to the <console>` -- single-line summary
   - `Log the <metrics: table> to the <console>` -- ASCII table with system metrics
   - `Log the <metrics: plain> to the <console>` -- detailed human-readable
   - `Log the <metrics: prometheus> to the <console>` -- Prometheus exposition format
