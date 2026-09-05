// ============================================================
// KernelCommand.swift
// AROCLI — `aro kernel`: the native Jupyter kernel (ARO-0091)
// ============================================================
//
// Two jobs:
//
//   aro kernel --connection-file <path>   serve one Jupyter session
//   aro kernel install                    register the kernelspec
//
// The serve form is what Jupyter invokes (see the kernelspec's
// argv); users only ever run `install`. No Python anywhere: the
// kernel speaks ZMQ directly via JupyterKernelServer.

#if !os(Windows)
import ArgumentParser
import Foundation

struct KernelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kernel",
        abstract: "Run the native Jupyter kernel, or install its kernelspec",
        discussion: """
            The native ARO Jupyter kernel (ARO-0091). Speaks the Jupyter \
            wire protocol over ZeroMQ directly — no Python, no ipykernel.

            Register it once:

              aro kernel install

            then pick "ARO" in JupyterLab / VS Code / DataSpell. Jupyter \
            starts `aro kernel --connection-file …` itself.

            Interrupt kills and replaces the kernel process (the session's \
            variables and definitions are gone) — a cell blocked inside \
            the runtime cannot be unwound, and an honest restart beats a \
            hang.
            """,
        subcommands: [KernelInstallCommand.self]
    )

    @Option(name: .customLong("connection-file"),
            help: "Jupyter connection file (passed by the front-end)")
    var connectionFile: String?

    func run() throws {
        guard let connectionFile else {
            throw ValidationError("""
                Missing --connection-file. This form is invoked by Jupyter; \
                to register the kernel, run: aro kernel install
                """)
        }
        let connection = try JupyterConnection.load(from: connectionFile)
        guard connection.transport == "tcp" else {
            throw ValidationError("Unsupported transport '\(connection.transport)' — only tcp is served.")
        }
        guard connection.signatureScheme == "hmac-sha256" || connection.key.isEmpty else {
            throw ValidationError("Unsupported signature scheme '\(connection.signatureScheme)'.")
        }
        let server = try JupyterKernelServer(connection: connection)
        server.run()
    }
}

struct KernelInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Write the ARO kernelspec into the user's Jupyter kernels directory"
    )

    @Option(help: "Kernelspec directory to write into (defaults to the user's Jupyter data dir)")
    var prefix: String?

    func run() throws {
        let kernelsDirectory: URL
        if let prefix {
            kernelsDirectory = URL(fileURLWithPath: prefix)
                .appendingPathComponent("kernels")
        } else {
            kernelsDirectory = Self.userJupyterDataDirectory()
                .appendingPathComponent("kernels")
        }
        let kernelDirectory = kernelsDirectory.appendingPathComponent("aro")
        try FileManager.default.createDirectory(
            at: kernelDirectory, withIntermediateDirectories: true)

        let spec: [String: Any] = [
            "argv": [Self.currentBinaryPath(), "kernel",
                     "--connection-file", "{connection_file}"],
            "display_name": "ARO",
            "language": "aro",
            // SIGINT kills the process and Jupyter restarts it — the
            // documented kill-and-replace interrupt (ARO-0091).
            "interrupt_mode": "signal",
        ]
        let data = try JSONSerialization.data(
            withJSONObject: spec, options: [.prettyPrinted, .sortedKeys])
        let specURL = kernelDirectory.appendingPathComponent("kernel.json")
        try data.write(to: specURL)

        print("Installed kernelspec: \(specURL.path)")
        print("Pick \"ARO\" in JupyterLab / VS Code / DataSpell.")
    }

    /// `$JUPYTER_DATA_DIR`, else the platform's user data dir —
    /// matching `jupyter --data-dir`.
    static func userJupyterDataDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["JUPYTER_DATA_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return home.appendingPathComponent("Library/Jupyter")
        #else
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("jupyter")
        }
        return home.appendingPathComponent(".local/share/jupyter")
        #endif
    }

    /// Absolute path of the running `aro` binary, for the kernelspec
    /// argv — Jupyter won't inherit the caller's PATH.
    static func currentBinaryPath() -> String {
        let argv0 = CommandLine.arguments[0]
        if argv0.hasPrefix("/") { return argv0 }
        if argv0.contains("/") {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(argv0).standardizedFileURL.path
        }
        // Bare name — resolved via PATH at launch; keep it and let
        // Jupyter's environment resolve it the same way.
        return argv0
    }
}
#endif
