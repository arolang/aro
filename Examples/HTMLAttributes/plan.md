# Read attributes out of parsed HTML

Create an ARO application that collects `href` and `src` attributes from a
document, rather than only element text.

- `main.aro` — one `Application-Start` feature set that:
  - binds a small HTML page with two linked anchors, one unlinked anchor, one
    image with a `src` and one without, and a `description` meta tag,
  - uses `Parse the <r: select> … with "a@href"` to collect the hrefs, and the
    same shape for `img@src` and `meta[name=description]@content`,
  - uses the same qualifier with no `@` to collect the anchors' text,
  - logs the anchor count against the href count, showing that an element
    without the attribute contributes nothing,
  - selects `a[href]` to show how to keep the two lists aligned when that
    matters.
