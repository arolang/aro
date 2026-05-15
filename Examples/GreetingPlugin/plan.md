# Build a greeting application using a Swift plugin

Create an ARO application that uses custom actions provided by a Swift plugin with the `Greeting` handle.

- `main.aro` -- The `Application-Start` feature set. Use the plugin's custom actions with the handle namespace: `Greeting.Greet the <greeting> with { name: "ARO Developer" }` and `Greeting.Farewell the <goodbye> with { name: "ARO Developer" }`. Extract the message from each response and log it.

- `Plugins/plugin-swift-hello/plugin.yaml` -- Plugin manifest with name `plugin-swift-hello`, handle `Greeting`, providing a `swift-plugin` type at `Sources/` path and `aro-files` at `features/` path.

- `Plugins/plugin-swift-hello/features/greetings.aro` -- Plugin-provided feature sets. A `Greet User: Greeting Handler` that extracts the name from the request, calls `Greet the <greeting> with <name>`, and returns OK. A `Farewell User: Greeting Handler` that does the same with `Farewell`.
