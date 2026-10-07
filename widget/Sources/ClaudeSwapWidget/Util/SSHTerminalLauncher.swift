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

    /// Opens `netbird ssh user@host` for a machine on the NetBird network.
    /// Both values end up on a shell command line, so anything outside plain
    /// account/host characters is refused rather than quoted.
    static func openNetbird(binary: String, user: String, host: String) {
        if let cmd = netbirdCommand(binary: binary, user: user, host: host) { runTerminal(cmd) }
    }

    /// The line typed into the new Terminal window; nil when a value is unsafe.
    /// Terminal feeds it to the interactive shell as keystrokes, so it must not
    /// start with "/" — shells commonly bind a leading "/" (or other first
    /// keys) to a widget such as an fzf directory picker, which would swallow
    /// the command. `command` keeps the absolute path while starting with a word.
    static func netbirdCommand(binary: String, user: String, host: String) -> String? {
        guard isSafe(user, extra: "._-"), isSafe(host, extra: ".-") else { return nil }
        return "command \(binary) ssh \(user)@\(host)"
    }

    static func isSafe(_ value: String, extra: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: extra))
        return !value.isEmpty && value.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
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
