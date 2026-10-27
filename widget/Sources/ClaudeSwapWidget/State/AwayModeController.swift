import AppKit
import IOKit.pwr_mgt

/// Away mode: keep the Mac from idle-sleeping so running work (claude
/// sessions, builds, downloads) carries on, then lock the screen with the
/// system lock screen (login password / Touch ID). The display may still
/// turn off. Ends on the next unlock; the power assertion also dies with the
/// process, so a crash never leaves the Mac stuck awake.
@MainActor
final class AwayModeController: ObservableObject {
    static let shared = AwayModeController()

    @Published private(set) var isAway = false

    private let holdAwake: () -> IOPMAssertionID?
    private let releaseAwake: (IOPMAssertionID) -> Void
    private let lockScreen: () -> Void
    private var assertionID: IOPMAssertionID?
    private var unlockObserver: NSObjectProtocol?

    init(
        holdAwake: @escaping () -> IOPMAssertionID? = AwayModeController.createAssertion,
        releaseAwake: @escaping (IOPMAssertionID) -> Void = { _ = IOPMAssertionRelease($0) },
        lockScreen: @escaping () -> Void = AwayModeController.lockNow
    ) {
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
        if assertionID == nil { assertionID = holdAwake() }
        isAway = assertionID != nil
        lockScreen()
    }

    func end() {
        if let id = assertionID { releaseAwake(id) }
        assertionID = nil
        isAway = false
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
