# Build a demo of guards, defaults and named file results

Create a single-file ARO application that exercises four language features which
used to require workarounds (GitLab #830).

In the `Application-Start` feature set, in four labelled sections:

1. **A default for an absent value.** `Extract` two values from the environment
   with a `default` clause: `ARO_DEMO_PORT` defaulting to `"8080"` and
   `ARO_DEMO_REGION` defaulting to `"eu-central"`. Log each. Neither variable is
   set when the example runs, so both print their defaults.

2. **Affix and membership guards.** Set `<path>` to `"/api/users"` and
   `<blocked>` to a list of two paths. Log three messages guarded by
   `starts with`, `ends with` and `not in` — the `ends with ".html"` one must not
   print. Then build a list of three file records and `Filter` it with
   `where <name> ends with ".aro"`, logging the count (2).

3. **A guarded Publish.** Compute `<score>` as 90 and publish it as
   `<headline-score>` under `when <score> > 50`. Log the published value.

4. **Two copies in one feature set.** Write two files, `Copy` each to a `.bak`
   under a result name of your own choosing (not the literal word `file`), `Move`
   one of the backups, then `Exists` both results and log them. Delete every file
   the example created so it leaves the directory as it found it.

Return OK at the end.
