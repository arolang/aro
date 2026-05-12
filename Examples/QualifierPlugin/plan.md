# Build a plugin qualifier demo with a Swift collection plugin

Create an ARO application that demonstrates plugin-provided qualifiers for transforming values. The Swift plugin `plugin-swift-collection` has handle `Collections` and provides qualifiers: pick-random, shuffle, reverse.

In `main.aro`, the `Application-Start` feature set:

1. Create a list of numbers [1, 2, 3, 4, 5].
2. Use the qualifier syntax to transform the list:
   - `Compute the <random-element: collections.pick-random> from the <numbers>` -- pick a random element.
   - `Compute the <shuffled: collections.shuffle> from the <numbers>` -- shuffle the list.
   - `Compute the <reversed: collections.reverse> from the <numbers>` -- reverse the list.
3. Apply qualifiers to strings: `Compute the <reversed-greeting: collections.reverse> from the <greeting>`.
4. Use qualifiers in expressions: `Log <numbers: collections.reverse> to the <console>`.

The plugin manifest `Plugins/plugin-swift-collection/plugin.yaml` declares handle `Collections` with a swift-plugin provider.
