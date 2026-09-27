# Bound an application's concurrency and its outbound request rate

Create an ARO application that sets both application-wide limits and then does
work that would otherwise exceed them.

- `main.aro`:
  - `Application-Start` configures `<application: concurrency>` to 2 and then
    `<http-client>` with `{ concurrency: 2, rate: "10/s" }` — several settings
    for one category go in one object, because two statements naming the same
    category would rebind an immutable binding.
  - It then runs a `parallel for each` over six items asking for
    `with <concurrency: 6>`, sleeping briefly in each iteration and emitting a
    `PageFetched` event.
  - A `PageFetched Handler` logs each page.

The two limits answer different questions: a ceiling is how many units of work
are in flight, a rate is how many may start per interval. The handler matters
because a handler woken by an `Emit` inside a bounded loop used to run outside
every bound.
