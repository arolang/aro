// ============================================================
// ResponsePayload.swift
// ARO Runtime - Rendering a response payload for a boundary
// ============================================================

import Foundation

/// The renderings of a `Response`'s payload, in one place.
///
/// A response used to carry two payloads: the values the program produced and
/// a *flattened* copy of them, built eagerly by `Return` for transport —
/// nested records spread into dot-notation keys, collections replaced by their
/// JSON text. The HTTP renderer then parsed that text back into a JSON value
/// so it could re-serialise it into the body, so every response containing a
/// list did encode → string → decode → encode, and every value of a type the
/// flattener did not know became `String(describing:)` (GitLab #711).
///
/// The payload is now the only stored representation and these are the
/// renderings of it:
///
///   - `jsonBody` goes straight to the bytes of an HTTP body. A list stays a
///     list, so the round trip is gone.
///   - `flatten` reproduces the old transport dictionary byte for byte, on
///     demand, for the CLI printer, `aro test` and `Response`'s identity.
///   - `soleFlatValue` answers the "exactly one value, and is it text?"
///     question the content-type sniffers ask, without building either.
///
/// What the flat form gives up by being computed rather than stored: a reader
/// that wants both shapes pays for the flattening every time it asks. The CLI
/// printer asks once per printed response and the HTTP renderers no longer ask
/// at all, which is the trade this is for.
///
/// The dot-notation key shape is *kept*, in both renderings. It reaches
/// clients — `Examples/SessionScopedCart` asserts `{"user.data":"test"}` — so
/// flattening nested records into dotted JSON keys is the response contract,
/// not an implementation detail of the old storage.
public enum ResponsePayload {

    // MARK: - Transport dictionary (the old `Response.data`)

    /// Flatten a payload into the transport dictionary responses used to
    /// store: nested records become dot-notation keys and collections become
    /// their JSON text.
    ///
    /// Mirrors what `ReturnAction` used to write eagerly, so anything still
    /// reading `Response.data` sees exactly what it saw before.
    public static func flatten(_ payload: [String: any Sendable]) -> [String: AnySendable] {
        var data: [String: AnySendable] = [:]
        data.reserveCapacity(payload.count)
        for (key, value) in payload {
            flatten(value, into: &data, prefix: key)
        }
        return data
    }

    private static func flatten(
        _ value: any Sendable,
        into data: inout [String: AnySendable],
        prefix: String
    ) {
        switch value {
        case let str as String:
            data[prefix] = AnySendable(str)
        case let int as Int:
            data[prefix] = AnySendable(int)
        case let double as Double:
            data[prefix] = AnySendable(double)
        case let bool as Bool:
            data[prefix] = AnySendable(bool)
        case let body as RequestBodyValue:
            // An unread request body is carried as itself, never stringified:
            // the renderers recognise it and stream it back out (GitLab #477).
            data[prefix] = AnySendable(body)
        case let anchored as AnchoredBody:
            data[prefix] = AnySendable(anchored)
        case let dict as [String: any Sendable]:
            for (key, nested) in dict {
                flatten(nested, into: &data, prefix: "\(prefix).\(key)")
            }
        case let array as [any Sendable]:
            data[prefix] = AnySendable(jsonText(for: array) ?? "[]")
        default:
            data[prefix] = AnySendable(String(describing: value))
        }
    }

    /// The JSON text of a collection, as the flat form spells it.
    ///
    /// Returns nil when the collection holds something `JSONSerialization`
    /// refuses — a non-finite `Double`, in practice, since
    /// `SendableConverter.toJSON` maps everything else onto a JSON type.
    public static func jsonText(for array: [any Sendable]) -> String? {
        let jsonArray = foundationArray(array)
        // try? is acceptable: a collection that cannot be serialised is
        // reported by the caller, which knows what it was rendering. The old
        // code logged `[ReturnAction] Warning:` here and substituted "[]";
        // `flatten` keeps that substitution so `Response.data` is unchanged,
        // and the HTTP renderers now fail the whole body instead of silently
        // shipping an empty list.
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonArray),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            FileHandle.standardError.write(
                Data("[ResponsePayload] Warning: collection is not JSON-serializable\n".utf8))
            return nil
        }
        return jsonString
    }

    // MARK: - JSON body (the HTTP renderers)

    /// The bytes of a response's JSON body.
    ///
    /// Shape: the one the flattened dictionary produced once the renderer had
    /// parsed its strings back — dotted keys for nested records, real JSON
    /// arrays for collections — reached without the intermediate text
    /// (GitLab #711).
    ///
    /// `whenEmpty` is appended, in order, when the payload renders to no keys
    /// at all: a response that carries no values answers with its status
    /// rather than with `{}`. The callers differ in what they put there, which
    /// is why it is a parameter and not a rule here.
    ///
    /// ## Why the graph is Foundation containers (GitLab #904)
    ///
    /// `JSONSerialization` is an Objective-C API. Handed a Swift-native
    /// `[String: Any]` / `[Any]` graph it bridges every container and every
    /// leaf individually on the way in, and that bridge was 1.67 ms of the
    /// 4.37 ms it took to serialise a 70 KB, 500-record body — 38% of the
    /// step, spent on nothing the client can see.
    ///
    /// So the graph is built as `NSMutableDictionary` / `NSMutableArray` with
    /// `NSString` / `NSNumber` leaves in the *same* walk that used to build
    /// the Swift one, and the serialiser gets a graph it already understands.
    /// Building it costs about 0.77 ms more than building the Swift graph did
    /// — bridging the leaves is now our line item rather than Foundation's —
    /// against 1.67 ms saved, so the step is ~15% cheaper overall.
    ///
    /// What this gives up: nothing about the *output*. `JSONSerialization`
    /// remains the only thing that formats a number, escapes a string or
    /// orders keys, which is the whole reason the graph was changed instead of
    /// the serialiser. Hand-writing JSON would have been faster still (3.75 ms
    /// against 5.86 ms for the whole step, measured) and was rejected: Darwin's
    /// `.sortedKeys` is a *collation* order rather than a byte order — it puts
    /// `item2` before `item10` and `a_b` before `a-b` — and corelibs-foundation
    /// collates differently again, so no single hand-rolled comparator can be
    /// byte-identical on both platforms. Number formatting has the same split
    /// (see `FormatSerializer.renderDouble`, GitLab #517).
    ///
    /// What it does *not* give up but cannot prove from a Mac: the bridge is a
    /// Darwin concept, and under corelibs-foundation `NSNumber` is a different
    /// implementation. A bridged `Bool` arriving as `1` instead of `true` is
    /// exactly the kind of difference that ships silently, so
    /// `ResponsePayloadRenderingTests` renders this route and the Swift-native
    /// one over a wide corpus and compares the bytes. That test is the Linux
    /// evidence; it runs in CI.
    ///
    /// Throws what `JSONSerialization` throws: a payload holding a value it
    /// refuses — a non-finite `Double`, in practice — is the caller's to
    /// report, since only the caller knows what it was rendering.
    /// ## Exact amounts take the other writer (GitLab #906)
    ///
    /// `JSONSerialization` cannot encode an `AROCurrency` — it is a Swift
    /// struct, not a Foundation object — and the two ways of making it
    /// acceptable both defeat the point of having it: `Double` reintroduces
    /// the binary-floating-point error the format exists to remove, and a
    /// string quotes itself into the body, which ARO-0019 §3.2.1 settled is a
    /// different wrong answer. So a payload carrying one is written by ARO's
    /// own JSON writer instead.
    ///
    /// **The decision is made here, before any graph is built**, and that
    /// ordering is the load-bearing part. Letting an amount into the
    /// Foundation graph and deciding afterwards would hand
    /// `JSONSerialization` an object it refuses: it throws, every caller's
    /// `try?` turns that into the status-only fallback body, and the client
    /// gets `{"status":"ok"}` with the money silently dropped. The route has
    /// to be chosen from the payload, not from the graph.
    ///
    /// It is also why this lives in `ResponsePayload` rather than at the two
    /// call sites. The interpreter and the compiled server both call this one
    /// function, so neither can drift from the other about which writer a
    /// money response got.
    public static func jsonBody(
        _ payload: [String: any Sendable],
        whenEmpty extras: [(key: String, value: String)] = []
    ) throws -> Data {
        if containsExactAmount(payload) {
            return try exactJSONBody(payload, whenEmpty: extras)
        }

        let json = NSMutableDictionary(capacity: payload.count)
        for (key, value) in payload {
            insert(value, as: key, into: json)
        }
        if json.count == 0 {
            for extra in extras {
                json[extra.key] = extra.value as NSString
            }
        }
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    /// Whether `value`, or anything nested in it, is an exact amount
    /// (GitLab #906).
    ///
    /// Reads the *payload*, which is Swift values — deliberately not the
    /// rendered graph, for the reason `jsonBody` gives.
    static func containsExactAmount(_ value: Any) -> Bool {
        switch value {
        case is AROCurrency:
            return true
        case let array as [any Sendable]:
            return array.contains { containsExactAmount($0) }
        case let dict as [String: any Sendable]:
            return dict.values.contains { containsExactAmount($0) }
        case let array as [Any]:
            return array.contains { containsExactAmount($0) }
        case let dict as [String: Any]:
            return dict.values.contains { containsExactAmount($0) }
        default:
            return false
        }
    }

    /// A body holding an exact amount, written by ARO's own JSON writer
    /// (GitLab #906).
    ///
    /// Mirrors the walk above with one difference: the graph stays
    /// Swift-native so an `AROCurrency` survives to the writer as itself.
    /// GitLab #904's Foundation graph exists to save a bridge on the way into
    /// `JSONSerialization`, and this route does not go there, so there is
    /// nothing for it to save — the hot path is untouched, and this one is
    /// only taken by a response that actually carries money.
    ///
    /// `ResponsePayloadRenderingTests` renders the same payload down both
    /// routes and compares, which is what keeps the two walks in step.
    private static func exactJSONBody(
        _ payload: [String: any Sendable],
        whenEmpty extras: [(key: String, value: String)] = []
    ) throws -> Data {
        var json: [String: Any] = [:]
        json.reserveCapacity(payload.count)
        for (key, value) in payload {
            insertExact(value, as: key, into: &json)
        }
        if json.isEmpty {
            for extra in extras {
                json[extra.key] = extra.value
            }
        }
        guard let data = FormatSerializer.serializeExactJSON(json).data(using: .utf8) else {
            throw ActionError.runtimeError(
                "Could not encode the response body as UTF-8")
        }
        return data
    }

    /// The Swift-native twin of `insert`, for the exact route.
    private static func insertExact(
        _ value: any Sendable, as key: String, into json: inout [String: Any]
    ) {
        switch value {
        case let str as String:
            json[key] = inlineJSONSwift(str)
        case let int as Int:
            json[key] = int
        case let double as Double:
            json[key] = double
        case let exact as AROCurrency:
            // Carried as itself. The writer spells it at its own scale, as a
            // number — which is the whole reason this route exists.
            json[key] = exact
        case let bool as Bool:
            json[key] = bool
        case let dict as [String: any Sendable]:
            for (nestedKey, nested) in dict {
                insertExact(nested, as: "\(key).\(nestedKey)", into: &json)
            }
        case let array as [any Sendable]:
            json[key] = array.map { exactValue($0) }
        default:
            json[key] = inlineJSONSwift(String(describing: value))
        }
    }

    /// One value of a collection, Swift-native, for the exact route.
    private static func exactValue(_ value: any Sendable) -> Any {
        switch value {
        case let exact as AROCurrency:
            return exact
        case let dict as [String: any Sendable]:
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (key, nested) in dict { out[key] = exactValue(nested) }
            return out
        case let array as [any Sendable]:
            return array.map { exactValue($0) }
        default:
            // String, Int, Double, Bool and the `toJSON` rules for Date, Data
            // and everything else — the same mapping `foundationValue`
            // delegates, landing on Swift objects rather than Foundation ones.
            return SendableConverter.toJSON(value)
        }
    }

    /// `inlineJSON` without the Foundation bridge: a string that *is* JSON
    /// text becomes the value it spells, for the Swift-native route.
    ///
    /// The parsed form comes back from `JSONSerialization` as Foundation
    /// containers either way, and `FormatSerializer.writeJSON` reads those —
    /// it asks `NSNumber` before the Swift casts, so a bridged `true` stays
    /// `true` rather than becoming `1`.
    private static func inlineJSONSwift(_ str: String) -> Any {
        guard str.hasPrefix("{") || str.hasPrefix("[") else { return str }
        // try? is acceptable: this is a probe, exactly as in `inlineJSON`. A
        // string that merely starts with "{" or "[" need not be JSON, and it
        // is returned unchanged when it is not, so nothing is lost.
        guard let data = str.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return str }
        return parsed
    }

    private static func insert(_ value: any Sendable, as key: String, into json: NSMutableDictionary) {
        switch value {
        case let str as String:
            json[key] = inlineJSON(str)
        case let int as Int:
            json[key] = int as NSNumber
        case let double as Double:
            json[key] = double as NSNumber
        case let bool as Bool:
            json[key] = bool as NSNumber
        case let dict as [String: any Sendable]:
            for (nestedKey, nested) in dict {
                insert(nested, as: "\(key).\(nestedKey)", into: json)
            }
        case let array as [any Sendable]:
            // The point of GitLab #711: the array goes into the body as an
            // array. It used to be serialised to text here and parsed back one
            // step later.
            json[key] = foundationArray(array)
        default:
            json[key] = inlineJSON(String(describing: value))
        }
    }

    /// A collection as the `NSArray` `JSONSerialization` wants, built in one
    /// walk (GitLab #904). Was `array.map { SendableConverter.toJSON($0) }`,
    /// which produced a Swift array for Foundation to bridge element by
    /// element.
    private static func foundationArray(_ array: [any Sendable]) -> NSMutableArray {
        let out = NSMutableArray(capacity: array.count)
        for element in array {
            out.add(foundationValue(element))
        }
        return out
    }

    /// One value of a collection, as a Foundation object.
    ///
    /// Mirrors `SendableConverter.toJSON` case for case — it is the same
    /// mapping onto JSON types, landing on Foundation objects rather than on
    /// Swift ones. The leaves `toJSON` reaches by a rule rather than by a type
    /// (`Date`, `Data`, and `String(describing:)` for everything else) are
    /// delegated to it, so that rule keeps a single definition.
    private static func foundationValue(_ value: any Sendable) -> Any {
        switch value {
        case let str as String:
            return str as NSString
        case let int as Int:
            return int as NSNumber
        case let double as Double:
            return double as NSNumber
        case let bool as Bool:
            return bool as NSNumber
        case let dict as [String: any Sendable]:
            let out = NSMutableDictionary(capacity: dict.count)
            for (key, nested) in dict {
                out[key] = foundationValue(nested)
            }
            return out
        case let array as [any Sendable]:
            return foundationArray(array)
        default:
            // NSNull, Date, Data and the `String(describing:)` fallback. Each
            // lands on a JSON scalar, which bridges to its Foundation object
            // on the way in.
            return SendableConverter.toJSON(value) as AnyObject
        }
    }

    /// A string that *is* JSON text becomes the value it spells.
    ///
    /// Pre-existing behaviour of both renderers, kept: a handler that returns
    /// text it built or parsed itself (`Render`, `Transform`, a plugin) still
    /// has it inlined rather than escaped into a JSON string. A plain string
    /// pays one prefix check.
    ///
    /// The parsed form already *is* Foundation containers — it came out of
    /// `JSONSerialization` — so this case needed no change for GitLab #904;
    /// only the unparsed string is bridged here instead of later.
    private static func inlineJSON(_ str: String) -> Any {
        guard str.hasPrefix("{") || str.hasPrefix("[") else { return str as NSString }
        // try? is acceptable: this is a probe. A string that merely starts
        // with "{" or "[" need not be JSON, and the string is returned
        // unchanged when it is not, so nothing is lost.
        guard let data = str.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return str as NSString }
        return parsed
    }

    // MARK: - Content-type sniffing

    /// What the flattened rendering's single entry is, when it has exactly one.
    ///
    /// The renderers sniff a content type off a response that carries one
    /// value — HTML, CSS, JavaScript, Prometheus text — and used to ask
    /// `data.count == 1` and then `data.values.first?.get() as String?`. This
    /// answers the same question off the payload, and spells the collection
    /// case separately so its JSON text is produced only where a caller
    /// actually needs it.
    public enum SoleFlatValue {
        /// No entries, or more than one.
        case notSingle
        /// One entry that renders as this text.
        case text(String)
        /// One entry that is a collection. Its flat rendering is JSON text,
        /// which no sniffer matches — every one of them tests a prefix, and
        /// the text begins with `[`.
        case collection([any Sendable])
        /// One entry that is a number, a boolean or an unread body. The old
        /// `get() as String?` answered nil for each of these, so every sniffer
        /// declined.
        case nonText
    }

    /// Classify the payload's single flattened entry.
    ///
    /// Walks records the way `flatten` does — a record contributes its leaves,
    /// an empty record contributes none — and stops as soon as a second leaf
    /// turns up.
    public static func soleFlatValue(_ payload: [String: any Sendable]) -> SoleFlatValue {
        var found: SoleFlatValue = .notSingle
        var count = 0
        collectLeaf(in: payload, count: &count, found: &found)
        return count == 1 ? found : .notSingle
    }

    private static func collectLeaf(
        in dict: [String: any Sendable],
        count: inout Int,
        found: inout SoleFlatValue
    ) {
        for (_, value) in dict {
            if count > 1 { return }
            switch value {
            case let nested as [String: any Sendable]:
                collectLeaf(in: nested, count: &count, found: &found)
            case let str as String:
                count += 1
                found = .text(str)
            case let array as [any Sendable]:
                count += 1
                found = .collection(array)
            case is Int, is Double, is Bool, is RequestBodyValue, is AnchoredBody:
                count += 1
                found = .nonText
            default:
                count += 1
                found = .text(String(describing: value))
            }
        }
    }

    // MARK: - Streamed bodies

    /// The unread request body a response answers with, if it answers with one.
    ///
    /// `Return`ing a body writes it straight back to the client chunk by chunk
    /// (GitLab #477), so this is asked before anything builds a body in memory.
    public static func unreadBody(in payload: [String: any Sendable]) -> (any UnreadBody)? {
        for value in payload.values {
            if let body = value as? any UnreadBody { return body }
        }
        return nil
    }
}
