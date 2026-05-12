# Build a custom service plugin demo

Create a single-file ARO application that calls a custom greeting service provided by an external plugin.

In `main.aro`, the `Application-Start` feature set calls the greeting service using `Call the <hello-msg> from the <greeting: hello> with { name: "ARO Developer" }` and `Call the <goodbye-msg> from the <greeting: goodbye> with { name: "ARO Developer" }`. Log both responses. Include an `Application-End: Success` handler.

The plugin is defined externally and referenced via `aro.yaml`.
