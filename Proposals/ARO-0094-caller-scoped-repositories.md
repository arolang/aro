# ARO-0094: Caller-Scoped Repositories

- **Status:** Draft ([Issue #885](https://git.ausdertechnik.de/arolang/aro/-/issues/885))
- **Author:** ARO Language Team
- **Created:** 2026-09-26
- **Related:** ARO-0007 (Events & Reactive), ARO-0008 (I/O Services), ARO-0048 (WebSocket), ARO-0073 (Store Files), ARO-0003 (Type System / OpenAPI), ARO-0006 (Error Philosophy), ARO-0005 (Application Architecture)

## Abstract

> **A repository belongs to somebody. Say who once, not at every statement.**

`-repository` is application-scoped. That is right for a catalogue and wrong
for a shopping cart, and an ARO server has no way to say which it meant.
Everything one caller stores, every other caller retrieves.

This proposal adds a **scope** to a repository, declared once where the
repository is declared, and resolved by the transport the caller arrived on. A
statement does not restate it, cannot forget it, and cannot disagree with
itself between two lines:

```aro
Declare the <cart-repository> with { scope: "session" }.
...
Store the <item> into the <cart-repository>.
```

The same statement is correct over HTTP, WebSocket and TCP. What differs is who
"the caller" is, and each transport answers that its own way.

---

## 1. Motivation

An ARO application is a set of feature sets triggered by events. Nothing in that
model says which *caller* caused the event, so nothing can scope data to one.
Today:

```aro
(addToCart: Shop API) {
    Extract the <item> from the <request: body>.
    Store the <item> into the <cart-repository>.   (* everyone's cart *)
    Return a <Created: status> with <item>.
}
```

Two users adding to their carts add to the same one. The language offers no
spelling that means otherwise.

Every other server framework solves this with a session object hung off a
request (`$_SESSION`, `request.session`, `req.session`, `ctx.session`). ARO has
no request object to hang anything off, and adding one would be a magic
variable of the kind the language has avoided everywhere else.

The observation this proposal rests on is that **scope is a property of the
repository, not of the statement**. A cart is per-user in every line of the
program that touches it. Saying so once is both less to write and impossible to
get inconsistently wrong.

---

## 2. Two scopes, because a socket is not a user

Three transports make it clear there are two distinct things, and conflating
them would be a security bug rather than an untidiness.

| Scope | Means | Established by | Ends | Revocable |
|-------|-------|----------------|------|-----------|
| `application` | the whole program | nothing — today's behaviour | process exit | n/a |
| `session` | one authenticated caller | credentials; carried by a cookie | idle or absolute expiry, or logout | **yes** |
| `connection` | one transport connection | the connection existing | disconnect | close the socket |

A **TCP connection is not a user.** Anyone who can open a socket gets one, the
protocol carries no credentials, and nothing about it survives a reconnect. If
`connection.id` were usable as an identity, an unauthenticated peer could read a
logged-in user's data by opening a socket. Two words in the language is what
makes that hard to write by accident.

A program that *wants* an authenticated socket peer authenticates it in-band and
promotes the connection to a session (§6).

---

## 3. Declaring a scope

### 3.1 Syntax

`Declare` is a new statement, valid in `Application-Start`:

```aro
Declare the <catalogue-repository> with { scope: "application" }.
Declare the <cart-repository>      with { scope: "session" }.
Declare the <partial-repository>   with { scope: "connection" }.
Declare the <sessions-repository>  with { scope: "application" }.
```

The object is the repository; `with` carries its properties. `scope` is the only
required one. An undeclared repository is `application`-scoped, which is exactly
today's behaviour — every existing program keeps working, unchanged.

### 3.1.1 Two things implementing this settled

**The scope value is quoted.** A bare word in an ARO object literal is a
*variable reference*, so `{ scope: session }` looks up a variable called
`session` and fails with "Undefined variable: session". `{ scope: "session" }`
is the spelling, and it matches `Configure the <stores: write-back> with
"manual"`.

**The repository goes in the result position, and inherits `Configure`'s
wart.** `Declare the <cart-repository> with { … }` binds `cart-repository` as
the statement's result, exactly as `Configure the <application: concurrency>`
binds `application`. Declaring the same repository twice in one feature set is
therefore an immutable-rebinding error rather than a scope error, with a
diagnostic about variables. That is the existing `Configure` behaviour — CLAUDE.md
already warns that "two statements naming the same category rebind an immutable
binding" — so this proposal inherits it rather than inventing it. It is one more
argument that these are the same verb ([#886](https://git.ausdertechnik.de/arolang/aro/-/issues/886)).

### 3.2 Why not a qualifier at the use site

The alternative considered was qualifying each statement:

```aro
Store the <item> into the <cart-repository: session>.    (* rejected as the default *)
```

It reads well and matches how ARO qualifies everything else. It is rejected as
the *default* on one ground: the scope is restated at every statement, so it can
be omitted at one of them, and the failure mode of a forgotten `: session` is
silently reading the application-wide repository — another user's cart, with no
error. A safety property that must be retyped correctly on every line is not a
safety property.

It survives as the **deliberate escape hatch**, for the rare cross-caller read:

```aro
Retrieve the <all-carts> from the <cart-repository: application>.
```

Explicit, rare, and greppable — which is what an audit of "who reads across
users?" needs. Widening scope this way is only legal from `application`-scoped
code; see §7.3.

### 3.3 Why not a naming convention

`<session-cart-repository>` was considered and rejected: it is stringly-typed,
carries no lifetime or eviction policy, and renaming a repository would silently
change its security scope.

---

## 4. How a caller is resolved, per transport

```
  HTTP request ──► cookie on every request ──────────┐
                                                      ├──► session id ──► session-scoped
  WS upgrade ────► cookie, read once at upgrade ─────┘                    repositories
                          │
                          └──► connection id ────────┐
                                                      ├──► connection-scoped
  TCP connect ───► connection id ────────────────────┘     repositories
```

| Transport | Default scope available | Identity from | Lifetime |
|-----------|------------------------|---------------|----------|
| HTTP | `session` | cookie, per request | expiry |
| WebSocket | `session` if the upgrade carried one, else `connection` | cookie at upgrade; connection thereafter | connection, bounded by expiry |
| TCP socket | `connection` | the connection | connection |

### 4.1 HTTP

The session cookie is validated on every request, before any feature set runs
(§8). A request with no valid cookie has no session.

### 4.2 WebSocket

A WebSocket has exactly one HTTP request in its life — the upgrade — and it
carries cookies like any other. The session is resolved **once, at upgrade**,
and held for the connection. Every subsequent frame is already attributed: no
per-frame cookie, no re-validation cost.

`createWebSocketUpgrader` already receives the request head in both
`shouldUpgrade` and `upgradePipelineHandler`, so the cookies are already
available and currently discarded.

Two consequences:

- **Expiry mid-connection.** A socket outlives an idle timeout trivially. This
  proposal specifies that an open WebSocket **holds its session open** — traffic
  on the socket is liveness, and refreshes `last-seen` exactly as an HTTP request
  does. The absolute expiry still applies, and reaching it **closes the socket**.
- **Logout closes the socket.** Deleting a session while a WebSocket holds it
  would leave a revoked user connected, so revocation reaches the connection
  table (§6.2).

### 4.3 TCP

A TCP peer gets a `connection` scope and no session. `session`-scoped
repositories are unresolvable from a `Socket Event Handler` until the connection
is promoted (§6.1), and touching one before that is a runtime error — not an
empty repository, and never the application-wide one.

---

## 5. What a program writes

The point of declaring scope once is that the handler bodies stop differing:

```aro
(Application-Start: Shop) {
    Declare the <cart-repository>      with { scope: "session" }.
    Declare the <partial-repository>   with { scope: "connection" }.
    Declare the <sessions-repository>  with { scope: "application" }.

    Start the <http-server> with <contract>.
    Start the <socket-server> with { port: 9000 }.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(addToCart: Shop API) {                          (* HTTP — session from the cookie *)
    Extract the <item> from the <request: body>.
    Store the <item> into the <cart-repository>.
    Return a <Created: status> with <item>.
}

(Handle Message: WebSocket Event Handler) {      (* WS — session resolved at upgrade *)
    Extract the <text> from the <event: message>.
    Store the <text> into the <cart-repository>.
    Return an <OK: status> for the <event>.
}

(Handle Data Received: Socket Event Handler) {   (* TCP — connection scope *)
    Extract the <chunk> from the <packet: buffer>.
    Store the <chunk> into the <partial-repository>.
    Return an <OK: status> for the <packet>.
}
```

Three transports, one spelling of `Store`.

---

## 6. Lifetime

### 6.1 Promotion

A socket peer that authenticates in-band becomes a session:

<!-- aro-check: skip — `Attach` is proposed, not yet implemented; this block specifies the promotion step -->
```aro
(Handle Data Received: Socket Event Handler) {
    Extract the <token> from the <packet: message>.
    Retrieve the <session> from the <sessions-repository> where <token> is <token>.
    Attach the <session> to the <connection>.
    Return an <OK: status> for the <packet>.
}
```

`Attach` binds a session to the current connection. Afterwards `session`-scoped
repositories resolve for it. Promotion is **not reversible** within a
connection: a connection that has been a session cannot become anonymous again,
because the alternative is a downgrade attack in one statement. Closing the
socket is how a peer stops being that session.

`Attach` with a `<session>` that is not in the sessions repository is an error.

### 6.2 Eviction

This is the obligation that makes the feature safe to run for a long time:

| Trigger | Effect |
|---------|--------|
| `socket.disconnected`, `websocket.disconnected` | drop that connection's `connection`-scoped repositories |
| idle expiry | drop the session's `session`-scoped repositories; close WebSockets holding it |
| absolute expiry | as above |
| `Delete` from the sessions repository (logout) | as above, immediately |

Without the first row, a long-running server leaks one repository per connection
for the life of the process. It is not an optimisation.

### 6.3 What `last-seen` means

Any request or frame attributed to a session refreshes it. This is what lets a
WebSocket hold a session open, and it is the same rule for HTTP.

---

## 7. Errors

Consistent with ARO-0006: the program contains the happy path, and the runtime
reconstructs what failed.

### 7.1 Unresolvable scope

Touching a `session`-scoped repository where no session exists — from
`Application-Start`, a `File Event Handler`, an un-promoted socket handler, or
`aro run` with no server at all — is an error:

```
Cannot store the item into the cart-repository: it is session-scoped and this
feature set has no session.
  Feature: Handle Data Received
  Business Activity: Socket Event Handler
```

It is **never** an empty repository and **never** a silent fall back to
application scope. Both of those turn a missing session into a cross-caller data
leak that no test would catch.

### 7.2 What `aro check` catches

Scope resolution is partly static. A feature set's trigger is known from its
business activity, so `aro check` reports, before the program runs:

- a `session`-scoped repository touched from `Application-Start`, a file, watch
  or repository-observer handler — none of which can ever have a caller;
- a `connection`-scoped repository touched from an HTTP route, which has no
  connection the program can see;
- a repository declared twice with different scopes;
- a scope other than `application`, `session` or `connection`.

A socket handler touching a `session` repository is *not* a check-time error,
because promotion may have happened. It is a runtime error when it has not.

### 7.3 Widening

`<repo: application>` on a repository declared `session` is legal only from
`application`-scoped code — a scheduled job, an admin route, `Application-Start`.
Reaching across callers from inside a caller's own request is refused at check
time, because that is the shape of an accidental leak rather than a deliberate
report.

---

## 8. The session cookie

### 8.1 Declared in the contract

ARO is contract-first for HTTP, and the session is part of the contract:

```yaml
components:
  securitySchemes:
    sessionAuth:
      type: apiKey
      in: cookie
      name: aro_session
security:
  - sessionAuth: []
```

`in: cookie` is the OpenAPI keyword, and `OpenAPISpec` already parses
`securitySchemes`. Declaring it here keeps the session visible to every tool
that reads the contract, and per-route `security:` decides which routes need
one.

**The WebSocket upgrade is an HTTP request but not an OpenAPI operation.** Its
security is declared on the server rather than the contract:

```aro
Start the <websocket-server> with { path: "/ws", security: sessionAuth,
                                     origins: ["https://shop.example"] }.
```

### 8.2 Requirements

- **Opaque identifier only.** The cookie carries an id; state stays server-side.
  This is what keeps logout meaningful — the cookie-storing frameworks cannot
  revoke, and ARO should not inherit that.
- **≥128 bits from a CSPRNG.**
- **`HttpOnly`** — XSS cannot read it.
- **`Secure`**, and the server **refuses to issue a session cookie over plain
  HTTP at all**. The attribute tells the browser what to do; it does not stop
  the server handing a session to a MITM in the first place.
- **`SameSite=Lax`** by default, `Strict` configurable.
- **`Origin` validated on WebSocket upgrade.** `SameSite` does not reliably
  protect a WS handshake, so a cookie-authenticated WebSocket is open to
  cross-site hijacking without it. Not optional, and it has no HTTP equivalent.
- **Rotate the id on privilege change** — the session-fixation defence.
- **Idle and absolute expiry**, both configurable.
- The cookie is **signed**, not encrypted: it is an opaque handle, so
  tamper-evidence is what is wanted and there is nothing to keep secret. The
  cookie is not a place to put data, and this proposal does not provide one.

### 8.3 Prerequisite

`SecurityEnforcer`'s cookie branch authenticates by presence:

```swift
return cookieHeader.contains("\(name)=")
```

`Cookie: aro_session=` passes; any value passes. Today that only gates routes.
The moment a cookie selects which caller's data a statement reads, it is a
complete authentication bypass. **Validating the cookie against the sessions
repository is a prerequisite of this proposal, not part of it.**

---

## 9. The sessions repository

Active sessions live in an ordinary application-scoped repository that the
application declares. No magic variable and no name the runtime conjures:

```aro
Declare the <sessions-repository> with { scope: "application" }.
```

A session record is at minimum:

| Field | Meaning |
|-------|---------|
| `id` | the opaque identifier in the cookie |
| `created` | when it was minted |
| `last-seen` | refreshed by any attributed request or frame |

Anything else — `user`, `roles`, `cart-id` — is the application's to add.

Because it is an ordinary repository, ordinary ARO works on it:

```aro
(logout: Shop API) {
    Extract the <id> from the <session: id>.
    Delete the <gone> from the <sessions-repository> where <id> is <id>.
    Return an <OK: status> for the <logout>.
}

(Audit Sessions: sessions-repository Observer) {
    Extract the <change> from the <event: changeType>.
    Log <change> to the <console>.
    Return an <OK: status> for the <audit>.
}
```

Revocation therefore works by construction, and audit logging is something an
application writes rather than machinery the runtime grows.

It may be `.store`-backed (ARO-0073) to survive a restart. A `.store`-backed
sessions repository means sessions outlive the process, which is a deployment
decision and not the default.

**What the runtime owns**, because it happens before any feature set runs:
minting ids, validating the cookie, resolving a connection to its session,
refreshing `last-seen`, evicting on disconnect and expiry, and refusing a
request whose cookie does not match.

### 9.1 Live connections

Connections are visible too, so an admin page can see who is connected and a
logout can close their sockets:

```aro
Declare the <connections-repository> with { scope: "application" }.
```

Maintained by the runtime, with `{ id, transport, session, connected }` per live
connection, and removed on disconnect. Read-only to ARO code: deleting a row
would mean "close that socket", which is `Close`'s job rather than `Delete`'s.

---

## 10. Storage

The storage key gains the caller:

```
        today:  (businessActivity, repository)
  this design:  (businessActivity, repository, scope-key)

  scope-key =  ""                       for application
               "session:<session-id>"   for session
               "conn:<connection-id>"   for connection
```

Application-scoped repositories keep the key they have today, so nothing about
existing storage changes.

`.store` files (ARO-0073) may back `application`-scoped repositories as they do
now. Backing a caller-scoped repository is **out of scope for this proposal**:
it raises a file-per-session lifecycle, and the expiry-deletes-the-file question
deserves its own design rather than a paragraph here.

---

## 11. Migration

Every repository today is application-scoped and stays so. `Declare` is
additive; a program that does not use it behaves exactly as it does now. There
is no deprecation and no rewrite.

---

## 12. Prior art

| Framework | Handle | State | Note |
|-----------|--------|-------|------|
| PHP | `$_SESSION` | server, id in cookie | a superglobal; implicit `session_start()` produced a generation of fixation bugs |
| Django | `request.session` | server; optional cookie backend | its own docs warn the cookie backend **cannot be invalidated on logout** |
| Rails | `session` | encrypted cookie | signed and encrypted, so the client holds unreadable data — same non-revocability |
| Koa | `ctx.session` | middleware's choice | nothing in the language knows |
| Vapor | `req.session` | server, `SessionsMiddleware` | typed, explicit, per-request |
| ASP.NET | `HttpContext.Session` | distributed cache | documented as not for sensitive data |
| Socket.IO | `socket.data`, rooms | server, per connection | the closest WS prior art: connection state, and connection→user is the app's job |

What ARO takes: **server-side state with an opaque cookie**, so logout means
something; and Socket.IO's separation of connection from user, because that
distinction is what keeps a TCP peer from being mistaken for a person.

What ARO does differently: none of these is a language feature. Every one is
middleware attaching a dictionary to a request object, which is why every one of
them lets you forget to use it. Declaring scope on the repository moves the
decision to the declaration, where it is made once and enforced everywhere.

---

## 13. Open questions

1. **Should this be `Configure` rather than a second verb?** Filed as
   [#886](https://git.ausdertechnik.de/arolang/aro/-/issues/886). Both take a
   subject and a `with` object of properties, both are startup-time, and both
   answer "how should this thing behave?". A rename is cheap before the verb
   exists and expensive after.
2. Should it also carry eviction policy (`max`, `ttl`), or does that belong
   with the existing repository configuration in ARO-0035?
3. Is `Attach` the right verb for promotion, and should it be spelled as an
   action on `<connection>` or on `<session>`?
4. Should a `session`-scoped repository fire `{repo} Observer`, and if so, does
   the observer run inside that session's scope? This proposal assumes yes to
   both, but has not worked through what an observer that writes to another
   session-scoped repository means.
5. Is the `connections-repository` worth its cost, or is it better exposed as a
   qualifier on the sessions repository?
6. Does `aro test` (ARO-0015) need a way to declare a session, so a Given/When/Then
   can exercise a session-scoped route at all?
