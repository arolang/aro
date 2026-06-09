# SOLARO License Notice

The source under `Sources/SOLARO/` and `Sources/SOLAROLauncher/`
is **source-available** under the terms documented separately from
the `aro` core MIT license. Per ADR-011 (issue #228):

- **Source visible** so the regulated-audience trust posture stays
  intact and contributors can read, audit, and propose changes.
- **Commercial use and redistribution** of compiled SOLARO binaries
  requires a paid license. Free trial flow is shipped in the
  installer.
- **Personal, non-commercial use is free.** Reading the source and
  building it locally for your own use is always allowed.

The exact paid-use license text ships with the binary distribution
and lives in `Editor/solaro-app/LICENSE.md` once the installer
pipeline is in place (#228 Phase 4 / ADR-012).

This is intentionally different from the `aro` core (parser,
runtime, CLI, debugger), which stays **MIT**. SOLARO inherits
nothing of that license — the two products ship under different
terms despite sharing Swift modules at the source level.

For commercial-license inquiries, see the [arolang/aro
discussions](https://git.ausdertechnik.de/arolang/aro/-/discussions)
(ADR-013) until a dedicated licensing channel exists.
