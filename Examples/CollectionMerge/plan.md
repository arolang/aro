# Build a collection merge demo

Create a single-file ARO application that demonstrates the `Merge` action for combining arrays, objects, and strings immutably.

In the `Application-Start` feature set, show four examples:

1. **Array merging** -- Create two fruit lists and merge them: `Merge the <all-fruits: fruits> with <more-fruits>`. Log both the original (unchanged) and the merged result.

2. **Object merging** -- Create a person object and a details object, merge them into `<full-profile>`.

3. **String concatenation** -- Create a greeting and a name, merge them into `<message>`.

4. **Update pattern** -- Create a user with an old email and an updates object with a new email and a verified field. Merge to create `<updated-user>`, showing how merge can apply patches.

Emphasize that originals remain unchanged (immutable design).
