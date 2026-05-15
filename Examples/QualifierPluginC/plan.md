# Build a plugin qualifier demo with a C collection plugin

Create an ARO application that demonstrates plugin-provided qualifiers from a C plugin. The `plugin-c-collection` has handle `List` and provides qualifiers: first, last, size.

In `main.aro`, the `Application-Start` feature set:

1. Create a list [10, 20, 30, 40, 50].
2. Use qualifier syntax: `Compute the <first-element: list.first> from the <numbers>`, `<last-element: list.last>`, and `<list-size: list.size>`.
3. Apply the size qualifier to a string: `Compute the <string-size: list.size> from the <message>`.

The plugin manifest `Plugins/plugin-c-collection/plugin.yaml` declares handle `List` with a c-plugin provider.
