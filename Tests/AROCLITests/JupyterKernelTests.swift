// ============================================================
// JupyterKernelTests.swift
// AROCLI — native Jupyter kernel wire pieces (ARO-0091)
// ============================================================
//
// The socket loops are exercised end-to-end by driving the kernel
// with jupyter_client; what belongs here is the part that must be
// exactly right byte-for-byte and is testable without a front-end:
// connection-file parsing, message framing + HMAC signing, the
// kernelspec install, and one real ZMQ loopback proving the
// wrapper moves multipart messages.

#if !os(Windows)
import Testing
import Foundation
@testable import AROCLI

@Suite("Jupyter kernel wire")
struct JupyterKernelWireTests {

    @Test("Connection file parses the five ports and the key")
    func connectionFile() throws {
        let json = """
        {"shell_port": 5001, "iopub_port": 5002, "stdin_port": 5003,
         "control_port": 5004, "hb_port": 5005, "ip": "127.0.0.1",
         "key": "secret", "transport": "tcp",
         "signature_scheme": "hmac-sha256", "kernel_name": "aro"}
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-conn-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)

        let connection = try JupyterConnection.load(from: url.path)
        #expect(connection.shellPort == 5001)
        #expect(connection.hbPort == 5005)
        #expect(connection.key == "secret")
        #expect(connection.endpoint(port: 5001) == "tcp://127.0.0.1:5001")
    }

    @Test("A signed message round-trips through serialize → parse")
    func signedRoundTrip() {
        let signer = JupyterSigner(key: "a-key")
        let message = JupyterWireMessage(
            identities: [Data("client".utf8)],
            header: JupyterWire.header(msgType: "execute_request", session: "s1"),
            parentHeader: [:],
            metadata: [:],
            content: ["code": "Log \"x\" to the <console>."]
        )
        let frames = JupyterWire.serialize(message, signer: signer)
        let parsed = JupyterWire.parse(frames: frames, signer: signer)

        #expect(parsed != nil)
        #expect(parsed?.msgType == "execute_request")
        #expect(parsed?.identities == [Data("client".utf8)])
        #expect(parsed?.content["code"] as? String == "Log \"x\" to the <console>.")
        #expect(parsed?.header["version"] as? String == "5.3")
    }

    @Test("A tampered message is dropped, not answered")
    func tamperedMessageDropped() {
        let signer = JupyterSigner(key: "a-key")
        let message = JupyterWireMessage(
            identities: [],
            header: JupyterWire.header(msgType: "execute_request", session: "s1"),
            parentHeader: [:], metadata: [:],
            content: ["code": "Log \"x\" to the <console>."]
        )
        var frames = JupyterWire.serialize(message, signer: signer)
        // Flip the content frame (the last one).
        frames[frames.count - 1] = Data(#"{"code":"Log \"evil\" to the <console>."}"#.utf8)

        #expect(JupyterWire.parse(frames: frames, signer: signer) == nil)
        // A different key also fails.
        #expect(JupyterWire.parse(
            frames: JupyterWire.serialize(message, signer: signer),
            signer: JupyterSigner(key: "other")) == nil)
    }

    @Test("An empty key runs unsigned")
    func unsignedRoundTrip() {
        let signer = JupyterSigner(key: "")
        let message = JupyterWireMessage(
            identities: [], header: JupyterWire.header(msgType: "kernel_info_request", session: "s"),
            parentHeader: [:], metadata: [:], content: [:]
        )
        let frames = JupyterWire.serialize(message, signer: signer)
        // Signature frame (right after the delimiter) is empty.
        let delimiterIndex = frames.firstIndex(of: JupyterWireMessage.delimiter)!
        #expect(frames[delimiterIndex + 1].isEmpty)
        #expect(JupyterWire.parse(frames: frames, signer: signer)?.msgType == "kernel_info_request")
    }

    @Test("ZMQ loopback: REP echoes a multipart message to REQ")
    func zmqLoopback() throws {
        let context = try #require(ZMQContext())
        let server = try #require(ZMQSocket(context: context, kind: .rep))
        // Ephemeral port: bind to *, read back… keep it simple with a
        // throwaway high port; retry a few in case one is taken.
        var bound: Int?
        for port in 39131...39141 {
            if (try? server.bind("tcp://127.0.0.1:\(port)")) != nil {
                bound = port
                break
            }
        }
        let port = try #require(bound)
        let client = try #require(ZMQSocket(context: context, kind: .req))
        try client.connect("tcp://127.0.0.1:\(port)")

        let echoThread = Thread {
            if let frames = server.receiveMultipart() {
                server.sendMultipart(frames)
            }
        }
        echoThread.start()

        client.sendMultipart([Data("ping".utf8), Data(), Data("pong".utf8)])
        let reply = client.receiveMultipart()
        #expect(reply == [Data("ping".utf8), Data(), Data("pong".utf8)])

        client.close()
        server.close()
        context.shutdown()
    }
}

@Suite("Jupyter kernelspec install")
struct JupyterKernelspecTests {

    @Test("Install writes a launchable kernel.json under the prefix")
    func installWritesSpec() throws {
        let prefix = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-kernelspec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: prefix) }

        var command = try KernelInstallCommand.parse(["--prefix", prefix.path])
        try command.run()

        let specURL = prefix.appendingPathComponent("kernels/aro/kernel.json")
        let data = try Data(contentsOf: specURL)
        let spec = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let argv = try #require(spec["argv"] as? [String])
        #expect(argv.contains("kernel"))
        #expect(argv.contains("--connection-file"))
        #expect(argv.contains("{connection_file}"))
        #expect(spec["language"] as? String == "aro")
        #expect(spec["interrupt_mode"] as? String == "signal")
    }
}
#endif
