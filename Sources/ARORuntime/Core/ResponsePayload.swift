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
///   - `jsonObject` goes straight to the JSON value an HTTP body is
///     serialised from. A list stays a list, so the round trip is gone.
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
        let jsonArray = array.map { SendableConverter.toJSON($0) }
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

    /// Render a payload into the JSON value an HTTP body is serialised from.
    ///
    /// Same shape the flattened dictionary produced once the renderer had
    /// parsed its strings back — dotted keys for nested records, real JSON
    /// arrays for collections — but reached without the intermediate text.
    public static func jsonObject(_ payload: [String: any Sendable]) -> [String: Any] {
        var json: [String: Any] = [:]
        json.reserveCapacity(payload.count)
        for (key, value) in payload {
            insert(value, as: key, into: &json)
        }
        return json
    }

    private static func insert(_ value: any Sendable, as key: String, into json: inout [String: Any]) {
        switch value {
        case let str as String:
            json[key] = inlineJSON(str)
        case let int as Int:
            json[key] = int
        case let double as Double:
            json[key] = double
        case let exact as AROCurrency:
            // Carried through as itself (GitLab #906). `String(describing:)`
            // via the `default` below would quote it into the body, and
            // widening it to Double is the precision loss `Currency` exists
            // to prevent. The body writer spells it exactly.
            json[key] = exact
        case let bool as Bool:
            json[key] = bool
        case let dict as [String: any Sendable]:
            for (nestedKey, nested) in dict {
                insert(nested, as: "\(key).\(nestedKey)", into: &json)
            }
        case let array as [any Sendable]:
            // The point of GitLab #711: the array goes into the body as an
            // array. It used to be serialised to text here and parsed back one
            // step later.
            json[key] = array.map { SendableConverter.toJSON($0) }
        default:
            json[key] = inlineJSON(String(describing: value))
        }
    }

    /// A string that *is* JSON text becomes the value it spells.
    ///
    /// Pre-existing behaviour of both renderers, kept: a handler that returns
    /// text it built or parsed itself (`Render`, `Transform`, a plugin) still
    /// has it inlined rather than escaped into a JSON string. A plain string
    /// pays one prefix check.
    private static func inlineJSON(_ str: String) -> Any {
        guard str.hasPrefix("{") || str.hasPrefix("[") else { return str }
        // try? is acceptable: this is a probe. A string that merely starts
        // with "{" or "[" need not be JSON, and the string is returned
        // unchanged when it is not, so nothing is lost.
        guard let data = str.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return str }
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
