import AppKit

/// Opens an interactive `ssh` session to a tracked host in Terminal.app.
///
/// Shared by the Server tab and the SSH manager so "Connect" behaves the same
/// everywhere. The command is built from the host's own fields (port, identity,
/// jump) — the same ones the monitor uses — so what you monitor is what you
/// connect to.
enum SSHTerminalLauncher {
    static func open(_ h: CswClient.SSHHostDTO) {
        var parts = ["ssh"]
        if let p = h.port, p > 0 { parts += ["-p", String(p)] }
        if let id = h.identityFile, !id.isEmpty { parts += ["-i", id] }
        if let j = h.jumpHost, !j.isEmpty { parts += ["-J", j] }
        parts.append(h.target.isEmpty ? h.name : h.target)
        runTerminal(parts.joined(separator: " "))
    }

    private static func runTerminal(_ cmd: String) {
        let escaped = cmd.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(escaped)\"\n"
            + "tell application \"Terminal\" to activate"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
