# Configuration Keys

`Configure` (ARO-0035) sets runtime settings from inside an ARO program:

```aro
Configure the <http-server: max-body> with "4MB".
Configure the <cache-repository: ttl> with 60.
```

The first thing to know is that **there is no closed registry of keys.**
`Configure` is one of `Update`'s verbs, and exactly two object bases reach
runtime state. Everything else takes a generic path that merges the value into
a dictionary bound to that name — it is a scoped value your own feature sets can
read back, and nothing more. A misspelled key is therefore silent.

---

## The keys that do something

| Written as | Sets | Default | Environment equivalent |
|---|---|---|---|
| `<http-server: max-body>` | Default limit on a request body that becomes a value, for routes with no `x-aro-max-body`. Accepts `"1MB"`, `"512KB"`, `"2MiB"` or a positive number of bytes. | `1MB` | `ARO_MAX_BODY` |
| `<http-server: max-request-body>` | Exact alias of `max-body`. | `1MB` | `ARO_MAX_BODY` |
| `<http-server: maxBody>` | Alias again, camelCase. **Avoid it**: a bad value under this spelling is ignored silently, where `max-body` raises. | `1MB` | `ARO_MAX_BODY` |
| `<«name»-repository: ttl>` | Time-to-live in **seconds** for rows in that repository; expired rows read as absent. Takes an Int or a Double. | none — rows never expire | — |
| `<«name»-repository: maxSize>` | Maximum row count; the oldest row is evicted past the cap. **camelCase only** — `max-size` silently does nothing. | none — unlimited | — |

A `Configure` statement wins over the environment variable: the variable seeds
the default, the statement assigns it.

`Configure` accepts `with`, `to`, `for`, `from` and `into`.

## Two traps

**The object form does not configure a repository.** The immutability hint
suggests writing several settings at once:

```aro
Configure the <cache-repository> with { ttl: 60, maxSize: 500 }.
```

That takes the generic path — it binds a dictionary and configures nothing.
Only the per-qualifier form reaches storage:

```aro
Configure the <cache-repository: ttl> with 60.
Configure the <cache-repository: maxSize> with 500.
```

**`<http-client: retries>` is not a key.** It appears in a comment in the REPL
source and is sometimes copied from there; it takes the generic path and has no
effect.

## Everything else

```aro
Configure the <validation: timeout> with 30.
```

This binds `<validation>` to `{ timeout: 30 }` in the current scope and marks
the category configured, so a later read of an unset setting answers null
rather than erroring. It is a convention for carrying your own settings, not a
runtime knob.
