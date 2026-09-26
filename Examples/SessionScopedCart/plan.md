# Session-Scoped Cart

A shop with two repositories that behave differently, and one line of ARO
saying why.

## What it demonstrates

`-repository` is application-scoped: every caller shares one. That is right for
a catalogue and wrong for a cart. ARO-0094 adds a **scope**, declared once where
the repository is declared:

```aro
Declare the <catalogue-repository> with { scope: "application" }.
Declare the <cart-repository>      with { scope: "session" }.
```

Nothing below restates it. `Store the <item> into the <cart-repository>.` is the
same statement it would be without the feature — what changed is *whose* cart it
writes to.

## The routes

| Route | What it shows |
|-------|---------------|
| `GET /catalogue` | An application-scoped repository, reachable with no caller at all — the route declares `security: []` |
| `POST /login` | `Attach the <session> to the <caller>.` mints a session and returns it as a `Set-Cookie` |
| `POST /cart` | A session-scoped write. Two browsers doing this write to two carts |
| `GET /cart` | A session-scoped read. Returns this caller's items, and nobody else's |
| `POST /logout` | `Delete` from the sessions repository. The cart goes with the session |

## The session

The cookie is declared in `openapi.yaml`, because ARO is contract-first and the
session is part of the contract:

```yaml
components:
  securitySchemes:
    sessionAuth:
      type: apiKey
      in: cookie
      name: aro_session
```

`in: cookie` is the OpenAPI keyword. Declaring it there keeps the session
visible to every tool that reads the contract, and per-route `security:` decides
which routes need one — `/catalogue` and `/login` do not.

What the cookie carries is an opaque id and nothing else. State stays
server-side, in the ordinary `sessions-repository` this program declares, which
is what makes `logout` a one-line `Delete` rather than a framework feature. A
session cookie is signed, `HttpOnly`, `SameSite=Lax`, and is not issued over
plain HTTP at all — `Configure the <session: secure> with false.` is how this
example says it is running on a laptop.

## Expected behaviour

```
POST /login                     → 200, Set-Cookie: aro_session=…; HttpOnly; SameSite=Lax
POST /cart  {"id":"hat"}        → 201
GET  /cart                      → 200, [{"id":"hat"}]
GET  /cart  (a second browser)  → 200, []            ← the point of the example
POST /logout                    → 200
GET  /cart                      → 401                ← the session is gone, and so is the cart
```

## Why it does not run in the integration harness

Driving this means being the same caller twice, and the harness's HTTP client
keeps cookies only when `HTTP::CookieJar` is installed. Without them every
request is a fresh caller — so an empty cart and a broken feature look
identical, and a green run would mean nothing. The executor picks the jar up
automatically when the module is present; until then the scoping itself is
covered by `CallerScopedStorageTests` and `SessionServiceTests`.
