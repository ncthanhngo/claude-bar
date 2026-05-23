import Foundation
import SwiftUI

/// Owns the long-lived gate IPC subprocess and surfaces pending prompts to
/// the UI. There is at most one pending prompt at a time — the MCP server's
/// AwaitApproval is synchronous, so a second prompt waits for the first to
/// resolve.
@MainActor
final class GateCoordinator: ObservableObject {
    /// Currently pending prompt; nil when nothing awaiting user decision.
    @Published private(set) var pending: GatePromptDTO?

    /// Visible countdown (seconds) until auto-cancel. UI binds for the
    /// 30-second timer bar / chip animation.
    @Published private(set) var secondsRemaining: Int = 30

    /// True when the gate proxy subprocess is connected.
    @Published private(set) var isConnected: Bool = false

    /// Last error from the proxy subprocess (rare; surfaces in Diagnostics).
    @Published var lastError: String?

    private var reader: GateStreamReader?
    private var countdownTask: Task<Void, Never>?

    /// Starts the proxy subprocess. Called once at app launch.
    func start() {
        guard reader == nil else { return }
        let r = GateStreamReader(
            yield: { [weak self] ev in
                Task { @MainActor [weak self] in self?.handle(ev) }
            },
            onTermination: { [weak self] code, stderr in
                Task { @MainActor [weak self] in
                    self?.isConnected = false
                    if code != 0 && code != 130 {
                        self?.lastError = "gate proxy exited \(code): \(stderr)"
                    }
                }
            }
        )
        guard let r else {
            lastError = "csw binary not found"
            return
        }
        reader = r
        do {
            try r.start()
        } catch {
            lastError = "gate proxy spawn failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        countdownTask?.cancel()
        countdownTask = nil
        reader?.stop()
        reader = nil
        isConnected = false
    }

    /// Approve the currently-pending prompt.
    func approve() {
        guard let p = pending, let r = reader else { return }
        r.respond(nonce: p.nonce, decision: .approved)
        clear()
    }

    /// Cancel the currently-pending prompt.
    func cancel() {
        guard let p = pending, let r = reader else { return }
        r.respond(nonce: p.nonce, decision: .cancelled)
        clear()
    }

    // MARK: - private

    private func handle(_ ev: GateStreamReader.Event) {
        switch ev {
        case .hello:
            isConnected = true
        case .prompt(let p):
            // If another prompt was pending (shouldn't happen — backend is
            // synchronous, one outstanding at a time), auto-cancel the old.
            if pending != nil { cancel() }
            pending = p
            startCountdown()
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        secondsRemaining = 30
        countdownTask = Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if Task.isCancelled { return }
                await MainActor.run {
                    if self.secondsRemaining > 0 { self.secondsRemaining -= 1 }
                }
            }
            // Timeout — the backend will also auto-cancel on its 30-sec
            // timer, but we send an explicit cancel for clean accounting.
            await MainActor.run { self?.cancel() }
        }
    }

    private func clear() {
        countdownTask?.cancel()
        countdownTask = nil
        pending = nil
        secondsRemaining = 30
    }
}
