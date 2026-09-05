// ============================================================
// JupyterMessage.swift
// aro kernel — Jupyter wire-protocol framing + HMAC signing
// ============================================================
//
// A Jupyter message on the wire is:
//
//   [routing identities…] <IDS|MSG> signature header parent metadata content [buffers…]
//
// where the four payload frames are JSON and the signature is
// hex(HMAC-SHA256(key, header ‖ parent ‖ metadata ‖ content)) —
// over the serialized bytes, in that order. An empty key means the
// front-end runs unsigned and the signature frame is empty.
//
// Verification failure drops the message rather than answering it:
// answering an unauthenticated request would defeat the point of
// the key, and Jupyter's own kernels do the same.

#if !os(Windows)
import Foundation
import Crypto

struct JupyterWireMessage {
    var identities: [Data]
    var header: [String: Any]
    var parentHeader: [String: Any]
    var metadata: [String: Any]
    var content: [String: Any]

    var msgType: String { header["msg_type"] as? String ?? "" }

    static let delimiter = Data("<IDS|MSG>".utf8)
}

struct JupyterSigner {
    /// Raw HMAC key bytes; empty disables signing.
    let key: Data

    init(key: String) {
        self.key = Data(key.utf8)
    }

    func signature(header: Data, parent: Data, metadata: Data, content: Data) -> String {
        guard !key.isEmpty else { return "" }
        var hmac = HMAC<SHA256>(key: SymmetricKey(data: key))
        hmac.update(data: header)
        hmac.update(data: parent)
        hmac.update(data: metadata)
        hmac.update(data: content)
        return hmac.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum JupyterWire {

    /// Parse a raw multipart message. Returns nil for frames that
    /// aren't a Jupyter message (no delimiter, too few frames) or
    /// whose signature doesn't verify.
    static func parse(frames: [Data], signer: JupyterSigner) -> JupyterWireMessage? {
        guard let delimiterIndex = frames.firstIndex(of: JupyterWireMessage.delimiter),
              frames.count >= delimiterIndex + 6 else {
            return nil
        }
        let identities = Array(frames[..<delimiterIndex])
        let signatureFrame = frames[delimiterIndex + 1]
        let headerData = frames[delimiterIndex + 2]
        let parentData = frames[delimiterIndex + 3]
        let metadataData = frames[delimiterIndex + 4]
        let contentData = frames[delimiterIndex + 5]

        if !signer.key.isEmpty {
            let expected = signer.signature(
                header: headerData, parent: parentData,
                metadata: metadataData, content: contentData)
            let received = String(data: signatureFrame, encoding: .utf8) ?? ""
            guard constantTimeEquals(expected, received) else {
                FileHandle.standardError.write(Data(
                    "[aro kernel] Warning: dropping message with bad signature\n".utf8))
                return nil
            }
        }

        func decode(_ data: Data) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }

        return JupyterWireMessage(
            identities: identities,
            header: decode(headerData),
            parentHeader: decode(parentData),
            metadata: decode(metadataData),
            content: decode(contentData)
        )
    }

    /// Serialize a message for the wire, signing it.
    static func serialize(_ message: JupyterWireMessage, signer: JupyterSigner) -> [Data] {
        func encode(_ object: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                ?? Data("{}".utf8)
        }
        let headerData = encode(message.header)
        let parentData = encode(message.parentHeader)
        let metadataData = encode(message.metadata)
        let contentData = encode(message.content)
        let signature = signer.signature(
            header: headerData, parent: parentData,
            metadata: metadataData, content: contentData)

        return message.identities
            + [JupyterWireMessage.delimiter,
               Data(signature.utf8),
               headerData, parentData, metadataData, contentData]
    }

    /// A fresh header in protocol 5.3 shape.
    static func header(msgType: String, session: String) -> [String: Any] {
        [
            "msg_id": UUID().uuidString,
            "session": session,
            "username": "aro",
            "date": isoNow(),
            "msg_type": msgType,
            "version": "5.3",
        ]
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    /// Timing-safe comparison — a signature check must not leak how
    /// many leading hex digits matched.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var difference: UInt8 = 0
        for index in aBytes.indices {
            difference |= aBytes[index] ^ bBytes[index]
        }
        return difference == 0
    }
}
#endif
