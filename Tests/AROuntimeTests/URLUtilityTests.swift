// ============================================================
// URLUtilityTests.swift
// ARO Runtime — URL resolution, defragmenting, normalising, splitting
// ARO-0019 §3.1a, GitLab #859
// ============================================================
//
// The crawler chapter built relative-URL resolution out of `Split` statements
// and string concatenation, and the result is wrong for several ordinary
// cases: `../`, a protocol-relative `//host/path`, and a fragment on a
// relative link. Those three are the tests that matter here.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("URL utilities (#859)")
struct URLUtilityTests {

    private static let base = "https://example.com/docs/guide/page.html?x=1#top"

    private func compute(
        _ qualifier: String,
        on input: any Sendable,
        with parameters: (any Sendable)? = nil
    ) throws -> any Sendable {
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: input)
        if let parameters { context.bind("_with_", value: parameters) }
        return try ComputeAction().executeSynchronously(
            result: ResultDescriptor(base: "out", specifiers: [qualifier], span: span),
            object: ObjectDescriptor(preposition: .from, base: "input", specifiers: [], span: span),
            context: context)
    }

    private func resolve(_ href: String, base: String = base) throws -> String {
        let value = try compute("url-resolve", on: href,
                                with: ["base": base] as [String: any Sendable])
        return try #require(value as? String)
    }

    // MARK: - The three cases concatenation gets wrong

    @Test("`../` climbs, rather than being pasted on")
    func dotDotClimbs() throws {
        #expect(try resolve("../other/x.html") == "https://example.com/docs/other/x.html")
        #expect(try resolve("../../top.html") == "https://example.com/top.html")
    }

    @Test("a protocol-relative URL takes the base's scheme")
    func protocolRelative() throws {
        // `//cdn.example.org/lib.js` is a real and common spelling, and
        // concatenation turns it into `https://example.com//cdn.example.org/…`.
        #expect(try resolve("//cdn.example.org/lib.js") == "https://cdn.example.org/lib.js")
    }

    @Test("a fragment-only link keeps the base's path and query")
    func fragmentOnly() throws {
        #expect(try resolve("#section")
                == "https://example.com/docs/guide/page.html?x=1#section")
    }

    // MARK: - The ordinary cases

    @Test("a root-relative link replaces the path")
    func rootRelative() throws {
        #expect(try resolve("/about") == "https://example.com/about")
    }

    @Test("a sibling link resolves against the directory, not the page")
    func siblingRelative() throws {
        #expect(try resolve("other.html") == "https://example.com/docs/guide/other.html")
    }

    @Test("an absolute URL passes through unchanged")
    func absolutePassesThrough() throws {
        // So resolving a page's links never has to ask which kind each one is.
        #expect(try resolve("https://other.test/z") == "https://other.test/z")
    }

    @Test("a query-only link keeps the path and replaces the query")
    func queryOnly() throws {
        #expect(try resolve("?y=2") == "https://example.com/docs/guide/page.html?y=2")
    }

    @Test("the base may be given bare as well as under `base:`")
    func bareBase() throws {
        let value = try compute("url-resolve", on: "/about", with: Self.base)
        #expect(value as? String == "https://example.com/about")
    }

    @Test("no base at all is an error naming what is missing")
    func missingBase() {
        #expect(throws: (any Error).self) {
            _ = try compute("url-resolve", on: "/about")
        }
    }

    // MARK: - Defragment

    @Test("the fragment goes and everything else stays")
    func defragment() throws {
        // Two URLs differing only in the fragment are the same *request*,
        // which is why a crawler strips it before deciding it has seen a page.
        #expect(try compute("url-defragment", on: Self.base) as? String
                == "https://example.com/docs/guide/page.html?x=1")
    }

    @Test("a URL with no fragment is unchanged")
    func defragmentNoFragment() throws {
        #expect(try compute("url-defragment", on: "https://example.com/a") as? String
                == "https://example.com/a")
    }

    @Test("something that is not a URL still loses its #tail")
    func defragmentNonURL() throws {
        // Lexical fallback: the qualifier should not fail on a value that is
        // almost a URL when the answer is obvious.
        #expect(try compute("url-defragment", on: "not a url#frag") as? String == "not a url")
    }

    // MARK: - Normalize

    @Test("scheme and host are lowercased, the path is not")
    func normalizeCase() throws {
        // A path is case-sensitive on most servers, so lowering it would
        // change which resource the URL names.
        #expect(try compute("url-normalize", on: "HTTPS://Example.COM/A/b") as? String
                == "https://example.com/A/b")
    }

    @Test("a default port is dropped, a non-default one is kept")
    func normalizePort() throws {
        #expect(try compute("url-normalize", on: "https://example.com:443/a") as? String
                == "https://example.com/a")
        #expect(try compute("url-normalize", on: "http://example.com:80/a") as? String
                == "http://example.com/a")
        #expect(try compute("url-normalize", on: "https://example.com:8443/a") as? String
                == "https://example.com:8443/a")
    }

    @Test("`.` and `..` are removed")
    func normalizeDots() throws {
        #expect(try compute("url-normalize", on: "https://example.com/a/./b/../c") as? String
                == "https://example.com/a/c")
    }

    @Test("an authority with no path gets `/`")
    func normalizeEmptyPath() throws {
        // `https://example.com` and `https://example.com/` are the same
        // resource, and a crawler comparing them as strings would disagree.
        #expect(try compute("url-normalize", on: "https://example.com") as? String
                == "https://example.com/")
    }

    @Test("the query is left exactly as written")
    func normalizeKeepsQuery() throws {
        // Parameter order can carry meaning, so reordering would change what
        // the URL means rather than normalise it.
        #expect(try compute("url-normalize", on: "https://example.com/a?b=2&a=1") as? String
                == "https://example.com/a?b=2&a=1")
    }

    // MARK: - Parts

    @Test("a URL splits into its parts")
    func parts() throws {
        let value = try compute("url-parts", on: Self.base)
        let parts = try #require(value as? [String: any Sendable])
        #expect(parts["scheme"] as? String == "https")
        #expect(parts["host"] as? String == "example.com")
        #expect(parts["path"] as? String == "/docs/guide/page.html")
        #expect(parts["query"] as? String == "x=1")
        #expect(parts["fragment"] as? String == "top")
    }

    @Test("an absent part is absent, not empty")
    func partsOmitsAbsent() throws {
        // The difference between "no port" and "port 0".
        let value = try compute("url-parts", on: "https://example.com/a")
        let parts = try #require(value as? [String: any Sendable])
        #expect(parts["port"] == nil)
        #expect(parts["query"] == nil)
        #expect(parts["fragment"] == nil)
        #expect(parts["host"] as? String == "example.com")
    }

    @Test("a port is a number")
    func partsPortIsInt() throws {
        let value = try compute("url-parts", on: "https://example.com:8443/a")
        let parts = try #require(value as? [String: any Sendable])
        #expect(parts["port"] as? Int == 8443)
    }

    // MARK: - The catalogs agree

    @Test("the parser's catalog knows every URL qualifier")
    func catalogAgrees() {
        // `aro check` never loads the runtime, so a green check has to mean
        // the qualifier exists.
        for name in ["url-resolve", "url-defragment", "url-normalize", "url-parts"] {
            #expect(ComputeQualifierCatalog.builtIns.contains(name), "missing \(name)")
        }
    }
}
