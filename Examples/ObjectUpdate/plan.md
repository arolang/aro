# Build an object update syntax demo

Create a single-file ARO application that demonstrates both forms of the `Update` action.

In the `Application-Start` feature set:

1. **Single-field updates** -- Create a profile object, then use `Update the <profile: role> with "editor"` and `Update the <profile: active> with true`.

2. **Multi-field update** -- Create a patch object and use `Update the <profile> with { role: <patch: role>, department: <patch: department> }`.

3. **Conditional update with when guard** -- Use `Update the <profile> with { role: "owner" } when <should-promote>` (fires when true) and a second update with `when <should-demote>` (does not fire when false).

Log the profile after each update to show the changes.
