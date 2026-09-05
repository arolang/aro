// ============================================================
// JupyterConnection.swift
// aro kernel — Jupyter connection-file parsing (ARO-0091)
// ============================================================
//
// Jupyter starts a kernel with `--connection-file <path>`; the file
// names five ports, a transport, and the HMAC key that signs every
// message. This is the complete contract between the front-end and
// a kernel process — parse it and the kernel knows where to bind.

#if !os(Windows)
import Foundation

struct JupyterConnection: Decodable {
    let transport: String        // "tcp" (the only one served here)
    let ip: String
    let shellPort: Int
    let iopubPort: Int
    let stdinPort: Int
    let controlPort: Int
    let hbPort: Int
    /// HMAC key; empty means unsigned messages.
    let key: String
    let signatureScheme: String  // "hmac-sha256"

    enum CodingKeys: String, CodingKey {
        case transport, ip, key
        case shellPort = "shell_port"
        case iopubPort = "iopub_port"
        case stdinPort = "stdin_port"
        case controlPort = "control_port"
        case hbPort = "hb_port"
        case signatureScheme = "signature_scheme"
    }

    static func load(from path: String) throws -> JupyterConnection {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(JupyterConnection.self, from: data)
    }

    func endpoint(port: Int) -> String {
        "\(transport)://\(ip):\(port)"
    }
}
#endif
