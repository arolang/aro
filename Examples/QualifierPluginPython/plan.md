# Build a plugin qualifier demo with a Python statistics plugin

Create an ARO application that demonstrates plugin-provided qualifiers from a Python plugin. The `plugin-python-collection` has handle `Stats` and provides qualifiers: sort, unique, sum, avg, min, max.

In `main.aro`, the `Application-Start` feature set:

1. Create a list [5, 2, 8, 1, 9, 3]. Use `Compute the <sorted-numbers: stats.sort> from the <numbers>`, then `<minimum: stats.min>` and `<maximum: stats.max>`.
2. Create a list [10, 20, 30, 40, 50]. Use `<total: stats.sum>` and `<average: stats.avg>`.
3. Create a list with duplicates [1, 2, 2, 3, 3, 3, 4]. Use `<unique-values: stats.unique>` to get deduplicated values.

The plugin manifest `Plugins/plugin-python-collection/plugin.yaml` declares handle `Stats` with a python-plugin provider.
