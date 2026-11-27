import Foundation

// Root-only AWDL switch for Claude Bar. Installed setuid root in
// /Library/PrivilegedHelperTools so the app can keep awdl0 down without a
// password prompt each time macOS brings it back. It accepts only
// `awdl down` or `awdl up` and runs /sbin/ifconfig with a fixed argv — no
// shell, no caller-supplied interface name, path or environment.
//
// Exit codes: 0 ok, 1 ifconfig failed, 2 bad arguments, 3 not running as root.

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2, args[0] == "awdl", args[1] == "down" || args[1] == "up" else {
    FileHandle.standardError.write(Data("usage: ClaudeBarNetHelper awdl down | up\n".utf8))
    exit(2)
}
// setuid gives euid 0; make the real uid root too so ifconfig runs as root.
guard geteuid() == 0, setuid(0) == 0 else {
    FileHandle.standardError.write(Data("must run as root\n".utf8))
    exit(3)
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
p.arguments = ["awdl0", args[1]]
p.environment = [:]
do { try p.run(); p.waitUntilExit() } catch { exit(1) }
exit(p.terminationStatus == 0 ? 0 : 1)
