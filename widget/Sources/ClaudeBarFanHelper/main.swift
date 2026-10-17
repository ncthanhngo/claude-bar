import Foundation
import SMCKit

// Root-only fan control for Claude Bar. Installed setuid root in
// /Library/PrivilegedHelperTools so the app can change fan speed without a
// password prompt each time. It accepts only `auto`, `max` or `rpm <n>` —
// nothing that reaches a shell, a path or the environment — and a custom
// speed is clamped to the fan's own min/max.
//
// Exit codes: 0 ok, 1 SMC write failed, 2 bad arguments, 3 not running as root.

guard let command = FanCommand.parse(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data("usage: ClaudeBarFanHelper auto | max | rpm <n>\n".utf8))
    exit(2)
}
// setuid gives euid 0; make the real uid root too so IOKit treats us as root.
guard geteuid() == 0, setuid(0) == 0 else {
    FileHandle.standardError.write(Data("must run as root\n".utf8))
    exit(3)
}
exit(Fans.apply(command) ? 0 : 1)
