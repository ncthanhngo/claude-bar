import Foundation

/// Auto-switch deferred because Claude Code CLI is currently running.
/// Holds the target account and the PIDs we're waiting on so the UI can show
/// progress and the store can re-evaluate when those PIDs disappear.
struct PendingSwitch: Equatable {
    let targetAccount: Account
    var blockingPIDs: [Int32]
    let detectedAt: Date
}
