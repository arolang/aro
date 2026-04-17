# Build a set operations demo

Create a single-file ARO application that demonstrates polymorphic set operations (intersect, difference, union) on lists, strings, and objects.

In the `Application-Start` feature set:

1. **List operations** -- Create two lists `[2,3,5]` and `[1,2,3,4]`. Compute `<common: intersect>`, `<only-a: difference>`, `<only-b: difference>` (reversed), and `<all: union>` using the qualifier syntax `Compute the <result: operation> from <a> with <b>`.

2. **Multiset semantics** -- Create lists with duplicates `[1,2,2,3]` and `[2,2,2,4]`. Show that intersect uses min count and difference removes matched counts.

3. **String operations** -- Apply intersect, difference, and union to strings "hello" and "bello", operating on characters.

4. **Object operations (deep recursive)** -- Create two objects with nested address fields. Intersect returns matching key-value pairs (recursively), difference returns keys in A not matching B, and union merges with A values winning.

5. **Filter with in/not in** -- Create items and an exclude list. Use `Filter the <included> from <items> where <value> in <exclude-list>` and `where <value> not in <exclude-list>`.

Log all results with descriptive labels.
