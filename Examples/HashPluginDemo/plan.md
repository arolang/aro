# Build a hash demo using a C plugin

Create an ARO application that uses custom hash actions provided by a C plugin with the `Hash` handle.

- `main.aro` -- The `Application-Start` feature set. Create a test string "Hello, ARO!". Use three custom hash actions: `Hash.Hash the <simple-result> from the <test-string>`, `Hash.DJB2 the <djb2-result> from the <test-string>`, and `Hash.FNV1a the <fnv-result> from the <test-string>`. Extract the hash value from each result and log it.

- `Plugins/plugin-c-hash/plugin.yaml` -- Plugin manifest with name `plugin-c-hash`, handle `Hash`, providing a `c-plugin` type. Build configuration uses clang with `-O2 -fPIC -shared` flags.
