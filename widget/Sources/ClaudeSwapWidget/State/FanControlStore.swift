import Foundation
import SMCKit

enum FanMode: String, CaseIterable, Identifiable {
    case auto, max, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .max: return "Max"
        case .custom: return "Custom"
        }
    }
}

/// Fan tab state. Speeds are read straight from the SMC (no privileges);
/// changing them goes through `ClaudeBarFanHelper`, a setuid-root tool the
/// app installs once into /Library/PrivilegedHelperTools behind the native
/// admin password prompt. The SMC is the source of truth for the mode, so
/// nothing is persisted — and the fans go back to Auto when the app quits.
@MainActor
final class FanControlStore: ObservableObject {
    @Published private(set) var fans: [FanReading] = []
    @Published private(set) var mode: FanMode = .auto
    /// Custom speed the slider shows, RPM.
    @Published var customRPM: Double = 0
    @Published private(set) var isApplying = false
    /// User-facing reason the last change failed; nil when it worked.
    @Published private(set) var error: String?

    private var didSyncMode = false

    /// Range of the custom slider — the first fan's limits; other fans get the
    /// same command, clamped to their own range by the helper.
    var rpmRange: ClosedRange<Double> {
        guard let f = fans.first, f.max > f.min else { return 0...1 }
        return f.min...f.max
    }

    /// Polls while the tab is visible; cancelled with the view's `.task`.
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    func refresh() async {
        fans = await Task.detached(priority: .utility) { Fans.read() }.value
        // Adopt whatever the SMC is doing on first read, so reopening the tab
        // shows the mode set earlier instead of resetting the picker.
        guard !didSyncMode, let first = fans.first else { return }
        didSyncMode = true
        mode = Self.mode(of: first)
        customRPM = first.isManual ? first.target : first.min
    }

    nonisolated static func mode(of fan: FanReading) -> FanMode {
        guard fan.isManual else { return .auto }
        return fan.target >= fan.max - 1 ? .max : .custom
    }

    func select(_ newMode: FanMode) {
        guard newMode != mode || error != nil else { return }
        mode = newMode
        switch newMode {
        case .auto: apply(.auto)
        case .max: apply(.max)
        case .custom: apply(.rpm(Int(customRPM.rounded())))
        }
    }

    /// Called when the slider is released.
    func commitCustomRPM() {
        guard mode == .custom else { return }
        apply(.rpm(Int(customRPM.rounded())))
    }

    private func apply(_ command: FanCommand) {
        isApplying = true
        error = nil
        Task {
            let result = await Task.detached { Self.run(command) }.value
            isApplying = false
            error = result
            await refresh()
        }
    }

    // MARK: - Helper

    /// Root-owned copy the app actually runs. Named per bundle id so Claude
    /// Bar and AI Bar never overwrite each other's helper.
    nonisolated static var installedHelper: String {
        "/Library/PrivilegedHelperTools/\(Bundle.main.bundleIdentifier ?? "dev.ncthanhngo.claude-bar").fan-helper"
    }

    /// The helper shipped inside the app, next to the main executable.
    nonisolated static var bundledHelper: String? {
        let path = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("ClaudeBarFanHelper").path
        return path.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    /// Installed, root-owned, setuid — and identical to the bundled copy, so an
    /// app update that changes the helper reinstalls it.
    nonisolated static func helperIsCurrent(bundled: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: installedHelper),
              (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue,
              perms & 0o4000 != 0 else { return false }
        return FileManager.default.contentsEqual(atPath: installedHelper, andPath: bundled)
    }

    /// Runs the command, installing the helper first if needed. Returns nil
    /// on success, else a message for the tab. Blocks — call off the main actor.
    nonisolated static func run(_ command: FanCommand) -> String? {
        guard let bundled = bundledHelper else { return "Không tìm thấy fan helper trong app." }
        if !helperIsCurrent(bundled: bundled) {
            let dest = installedHelper
            let ok = Shell.admin("mkdir -p /Library/PrivilegedHelperTools && cp \(quoted(bundled)) \(quoted(dest))"
                + " && chown root:wheel \(quoted(dest)) && chmod 4755 \(quoted(dest))")
            guard ok else { return "Cần quyền admin để điều khiển quạt." }
        }
        switch status(of: installedHelper, command.arguments) {
        case 0: return nil
        case 3: return "Fan helper không có quyền root."
        default: return "Mac này không cho đổi tốc độ quạt."
        }
    }

    /// Puts the fans back on Auto if they were left forced — on quit, and on
    /// launch in case the app crashed while Max/Custom was on. Never prompts:
    /// does nothing unless the helper is already installed.
    nonisolated static func restoreAuto() {
        guard FileManager.default.isExecutableFile(atPath: installedHelper),
              Fans.read().contains(where: \.isManual) else { return }
        _ = status(of: installedHelper, FanCommand.auto.arguments)
    }

    private nonisolated static func status(of path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    private nonisolated static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
