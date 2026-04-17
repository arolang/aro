# Build a for-each loop demo

Create a single-file ARO application demonstrating all for-each loop variants.

In the `Application-Start` feature set:

1. Create a list of user objects with fields `name`, `active` (boolean), and `score`.

2. **Basic for-each** -- Iterate over users and log each user's name. Then iterate again and log each full user object.

3. **Filtered for-each** -- Use `for each <user> in <users> where <user: active> is true` to iterate only over active users, logging their names.

4. **Indexed for-each** -- Use `for each <user> at <index> in <users>` to access the loop index. Compute `<position>` as `<index> + 1` and log it.

5. **Nested for-each** -- Create a list of team objects, each with a `name` and a `members` list. Iterate over teams, logging the team name, then iterate over each team's members logging each member name.

Return OK at the end.
