// ============================================================
// HTTPStatusCatalog.swift
// AROParser — the status names `Return a <X: status>` accepts
// ============================================================
//
// There were two copies of this mapping and they disagreed: the
// interpreter knew twelve names, the compiled binary knew five, and both
// fell through to 200 for anything else. So `Return a <TooManyRequests:
// status>` answered 200 in one mode and 200 in the other — silently, and
// for different reasons (GitLab #830 item 15).
//
// Silent is the problem. A status name is a claim about what happened,
// and a typo in it does not fail, does not warn, and produces a
// successful-looking response to a request that was rejected. This is the
// same shape as the closed qualifier namespace (ARO-0019 §3.3): a
// misspelling used to be indistinguishable from a correct spelling.
//
// The catalog lives in AROParser, not ARORuntime, for the same reason
// `ComputeQualifierCatalog` does — `aro check` must be able to reject an
// unknown name without loading a runtime.

import Foundation

/// The HTTP status names ARO understands, and the codes they mean.
public enum HTTPStatusCatalog {

    /// Every accepted spelling, normalised, mapped to its code.
    ///
    /// Several names are deliberately offered for one code. `Invalid`
    /// reads better than `BadRequest` in a validation feature set, and
    /// ARO's whole premise is that the statement should read like the
    /// sentence somebody would say.
    public static let byName: [String: Int] = [
        // 2xx
        "ok": 200, "success": 200,
        "created": 201,
        "accepted": 202,
        "nocontent": 204,

        // 3xx — enough to redirect, which a contract-first server does
        // for canonical URLs and for post/redirect/get.
        "movedpermanently": 301,
        "found": 302,
        "seeother": 303,
        "notmodified": 304,
        "temporaryredirect": 307,
        "permanentredirect": 308,

        // 4xx
        "badrequest": 400, "invalid": 400,
        "unauthorized": 401,
        "paymentrequired": 402,
        "forbidden": 403,
        "notfound": 404,
        "methodnotallowed": 405,
        "notacceptable": 406,
        "requesttimeout": 408,
        "conflict": 409,
        "gone": 410,
        "preconditionfailed": 412,
        "payloadtoolarge": 413, "contenttoolarge": 413,
        "uritoolong": 414,
        "unsupportedmediatype": 415,
        "unprocessable": 422, "unprocessableentity": 422, "unprocessablecontent": 422,
        "toomanyrequests": 429, "ratelimited": 429,

        // 5xx
        "error": 500, "servererror": 500, "internalerror": 500,
        "notimplemented": 501,
        "badgateway": 502,
        "unavailable": 503, "serviceunavailable": 503,
        "gatewaytimeout": 504,
    ]

    /// The canonical spelling for each code, for diagnostics and for the
    /// reason phrase on the wire.
    public static let canonicalName: [Int: String] = [
        200: "OK", 201: "Created", 202: "Accepted", 204: "NoContent",
        301: "MovedPermanently", 302: "Found", 303: "SeeOther",
        304: "NotModified", 307: "TemporaryRedirect", 308: "PermanentRedirect",
        400: "BadRequest", 401: "Unauthorized", 402: "PaymentRequired",
        403: "Forbidden", 404: "NotFound", 405: "MethodNotAllowed",
        406: "NotAcceptable", 408: "RequestTimeout", 409: "Conflict",
        410: "Gone", 412: "PreconditionFailed", 413: "PayloadTooLarge",
        414: "UriTooLong", 415: "UnsupportedMediaType", 422: "Unprocessable",
        429: "TooManyRequests",
        500: "Error", 501: "NotImplemented", 502: "BadGateway",
        503: "Unavailable", 504: "GatewayTimeout",
    ]

    /// The reason phrase HTTP itself uses, which is not always what ARO
    /// calls the status: ARO says `Unprocessable`, the wire says
    /// `Unprocessable Content`.
    public static let reasonPhrase: [Int: String] = [
        200: "OK", 201: "Created", 202: "Accepted", 204: "No Content",
        301: "Moved Permanently", 302: "Found", 303: "See Other",
        304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect",
        400: "Bad Request", 401: "Unauthorized", 402: "Payment Required",
        403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
        406: "Not Acceptable", 408: "Request Timeout", 409: "Conflict",
        410: "Gone", 412: "Precondition Failed", 413: "Content Too Large",
        414: "URI Too Long", 415: "Unsupported Media Type",
        422: "Unprocessable Content", 429: "Too Many Requests",
        500: "Internal Server Error", 501: "Not Implemented",
        502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout",
    ]

    /// Normalise a written name for lookup: case and the separators people
    /// reach for (`no-content`, `No_Content`, `not found`) are not
    /// distinctions worth having.
    public static func normalize(_ name: String) -> String {
        name.lowercased().filter { $0 != "-" && $0 != "_" && $0 != " " }
    }

    /// The code for a written status name, or `nil` when it is not one we
    /// know — which is the caller's cue to say so rather than answer 200.
    public static func code(for name: String) -> Int? {
        byName[normalize(name)]
    }

    /// Whether this is a status name at all.
    public static func isKnown(_ name: String) -> Bool {
        byName[normalize(name)] != nil
    }

    /// The reason phrase for a code, falling back to the class.
    public static func reason(for code: Int) -> String {
        if let phrase = reasonPhrase[code] { return phrase }
        switch code {
        case 200..<300: return "OK"
        case 300..<400: return "Redirect"
        case 400..<500: return "Client Error"
        case 500..<600: return "Server Error"
        default: return "Unknown"
        }
    }

    /// The closest known name to a misspelling, for the diagnostic.
    ///
    /// A plain edit distance on the normalised spelling. `NotFoudn` should
    /// find `NotFound`; `Teapot` should find nothing, and the message then
    /// says only that the name is unknown.
    public static func closestMatch(to name: String) -> String? {
        let target = normalize(name)
        guard !target.isEmpty else { return nil }
        // Distance beyond a third of the word is not a typo, it is a
        // different word, and guessing there is worse than not guessing.
        let budget = max(1, target.count / 3)
        var best: (name: String, distance: Int)?
        for (candidate, code) in byName {
            let d = editDistance(target, candidate)
            guard d <= budget else { continue }
            if best == nil || d < best!.distance {
                best = (canonicalName[code] ?? candidate, d)
            }
        }
        return best?.name
    }

    /// Every canonical name, sorted by code then name — the list a
    /// diagnostic prints when it has nothing better to suggest.
    public static var allCanonicalNames: [String] {
        canonicalName.sorted { $0.key == $1.key ? $0.value < $1.value : $0.key < $1.key }
            .map(\.value)
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
