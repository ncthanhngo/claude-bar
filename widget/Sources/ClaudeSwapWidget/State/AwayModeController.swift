import AppKit
import IOKit.pwr_mgt

/// Away mode: keep the Mac from idle-sleeping so running work (claude
/// sessions, builds, downloads) carries on, then lock the screen with the
/// system lock screen (login password / Touch ID). The display may still
/// turn off. Ends on the next unlock; the power assertion also dies with the
/// process, so a crash never leaves the Mac stuck awake.
///
/// The lock only protects anything when the account has a password and the
/// screen asks for it at once, so `start()` refuses until both are set and
/// sends the user to the matching System Settings pane.
@MainActor
final class AwayModeController: ObservableObject {
    static let shared = AwayModeController()

    enum Readiness: Equatable { case ready, noPassword, lockDelayed }

    @Published private(set) var isAway = false

    private let readiness: @MainActor () -> Readiness
    private let explain: @MainActor (Readiness) -> Void
    private let holdAwake: () -> IOPMAssertionID?
    private let releaseAwake: (IOPMAssertionID) -> Void
    private let lockScreen: () -> Void
    private var assertionID: IOPMAssertionID?
    private var unlockObserver: NSObjectProtocol?

    init(
        readiness: @escaping @MainActor () -> Readiness = AwayModeController.checkReadiness,
        explain: @escaping @MainActor (Readiness) -> Void = AwayModeController.showSetupAlert,
        holdAwake: @escaping () -> IOPMAssertionID? = AwayModeController.createAssertion,
        releaseAwake: @escaping (IOPMAssertionID) -> Void = { _ = IOPMAssertionRelease($0) },
        lockScreen: @escaping () -> Void = AwayModeController.lockNow
    ) {
        self.readiness = readiness
        self.explain = explain
        self.holdAwake = holdAwake
        self.releaseAwake = releaseAwake
        self.lockScreen = lockScreen
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func start() {
        let state = readiness()
        guard state == .ready else { explain(state); return }
        if assertionID == nil { assertionID = holdAwake() }
        isAway = assertionID != nil
        lockScreen()
    }

    func end() {
        if let id = assertionID { releaseAwake(id) }
        assertionID = nil
        isAway = false
    }

    /// Once a password is seen it stays set for this run — skips repeating
    /// the empty-password probe, which counts as a failed login each time.
    private static var passwordSeen = false

    private static func checkReadiness() -> Readiness {
        if !passwordSeen {
            // dscl exits 0 only when the empty string is the account password.
            if run("/usr/bin/dscl", ["/Search", "-authonly", NSUserName(), ""]).status == 0 {
                return .noPassword
            }
            passwordSeen = true
        }
        // Prints e.g. "screenLock delay is immediate" / "screenLock is off".
        let lock = run("/usr/sbin/sysadminctl", ["-screenLock", "status"])
        guard lock.status == 0 else { return .ready }  // can't tell — don't block
        return lock.output.contains("immediate") ? .ready : .lockDelayed
    }

    private static func showSetupAlert(_ state: Readiness) {
        let alert = NSAlert()
        let pane: String
        switch state {
        case .noPassword:
            alert.messageText = "Set a login password first"
            alert.informativeText = "Your Mac account has no password, so a locked screen would open for anyone. Add a password in Users & Groups, then press ⌥X again."
            pane = "com.apple.Users-Groups-Settings.extension"
        case .lockDelayed, .ready:
            alert.messageText = "Require a password right away"
            alert.informativeText = "Set “Require password after screen saver begins or display is turned off” to Immediately in Lock Screen settings, then press ⌥X again."
            pane = "com.apple.Lock-Screen-Settings.extension"
        }
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private nonisolated static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.standardOutput = pipe
        task.standardError = pipe
        guard (try? task.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private nonisolated static func createAssertion() -> IOPMAssertionID? {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Claude Bar away mode — keeping running work alive" as CFString,
            &id
        )
        return result == kIOReturnSuccess ? id : nil
    }

    /// Same lock as  → Lock Screen (⌃⌘Q). Falls back to sleeping the
    /// display, which locks when "Require password" is set to immediately.
    private nonisolated static func lockNow() {
        typealias LockFn = @convention(c) () -> Int32
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        if let handle = dlopen(path, RTLD_LAZY),
           let sym = dlsym(handle, "SACLockScreenImmediate") {
            _ = unsafeBitCast(sym, to: LockFn.self)()
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        try? task.run()
    }
}
