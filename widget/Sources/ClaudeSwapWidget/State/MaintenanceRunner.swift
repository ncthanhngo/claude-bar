import Foundation

/// Runs one-click macOS maintenance tasks. The no-sudo ones run directly; flush
/// DNS needs admin and prompts via osascript. Each task reports a status line.
@MainActor
final class MaintenanceRunner: ObservableObject {
    /// id of the task currently running (drives the per-row spinner), or nil.
    @Published var working: String?
    @Published var status: String?

    private func run(_ id: String, _ work: @escaping () -> String) {
        guard working == nil else { return }
        working = id
        Task {
            let msg = await Task.detached { work() }.value
            self.status = msg
            self.working = nil
        }
    }

    func emptyTrash() {
        run("trash") {
            _ = Shell.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"])
            return "Đã đổ Thùng rác."
        }
    }

    func restartDock() {
        run("dock") { _ = Shell.sh("killall Dock"); return "Đã khởi động lại Dock." }
    }

    func restartFinder() {
        run("finder") { _ = Shell.sh("killall Finder"); return "Đã khởi động lại Finder." }
    }

    func rebuildLaunchServices() {
        run("ls") {
            _ = Shell.sh("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user")
            return "Đã dựng lại Launch Services (menu Mở bằng…)."
        }
    }

    func clearFontCache() {
        run("font") { _ = Shell.sh("atsutil databases -removeUser"); return "Đã xoá font cache (người dùng)." }
    }

    func flushDNS() {
        run("dns") {
            let ok = Shell.admin("dscacheutil -flushcache; killall -HUP mDNSResponder")
            return ok ? "Đã flush DNS cache." : "Flush DNS bị huỷ hoặc thất bại."
        }
    }
}
