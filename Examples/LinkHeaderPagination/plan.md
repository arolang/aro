# Build an RFC 8288 Link header pagination parser

Create a single-file ARO application that demonstrates parsing HTTP Link headers for pagination.

In the `Application-Start` feature set, create a Link header string containing next, prev, last, and first URLs in standard RFC 8288 format. Use `Parse the <pagination: link-header> from the <link-value>` to parse it into a rel-keyed dictionary. Extract individual URLs using `Extract the <next-url> from the <pagination: next>`, and similarly for prev, last, and first. Log all extracted URLs.
