# Resolve and compare URLs without string surgery

Create an ARO application that uses the URL qualifiers instead of `Split` and
concatenation.

- `main.aro` — one `Application-Start` feature set that, against a base page
  URL with a query and a fragment:
  - resolves `../other/x.html`, a protocol-relative `//cdn…/lib.js`, and a
    fragment-only `#section` — the three cases concatenation gets wrong,
  - resolves an already-absolute URL to show it passes through,
  - strips the fragment with `url-defragment`,
  - canonicalises `HTTPS://Example.COM:443/a/./b/../c` with `url-normalize`,
  - splits the base URL with `url-parts` and logs the scheme, host, path,
    query and fragment.
