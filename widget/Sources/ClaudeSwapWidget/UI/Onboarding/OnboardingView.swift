import SwiftUI
import AppKit

/// Two-step welcome flow. Step 1 adds the first account via the existing
/// LoginCoordinator; Step 2 lets the user opt into Auto-swap / IDE reload /
/// Cloud Sync / Local MCP. Cloud Sync + MCP opens the relevant Settings
/// tab after Finish — passphrase / connector setup happens there rather
/// than mid-wizard.
struct OnboardingView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var loginCoordinator: LoginCoordinator
    @EnvironmentObject private var settings: AppSettings

    let onFinish: () -> Void
    let onSkip: () -> Void

    enum Step { case welcome, features }
    @State private var step: Step = .welcome

    @State private var optAutoSwap: Bool = false
    @State private var optIDEReload: Bool = false
    @State private var optCloudSync: Bool = false
    @State private var optLocalMCP: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .welcome:  welcomeStep
            case .features: featuresStep
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: store.snapshot?.accounts.count ?? 0) { _, newCount in
            // Auto-advance once the first account has been added through
            // the LoginCoordinator (the prompt closes itself).
            if step == .welcome, newCount > 0 {
                withAnimation(.easeInOut(duration: 0.25)) { step = .features }
            }
        }
    }

    // MARK: - Step 1

    private var welcomeStep: some View {
        VStack(alignment: .center, spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
                .padding(.top, 8)
            Text("Welcome to Claude Bar")
                .font(.system(size: 22, weight: .semibold))
            Text("A menu-bar manager for multiple Claude Code accounts. Switch between accounts instantly, auto-swap when quota runs out, and keep your IDE in sync.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Button {
                    loginCoordinator.begin()
                } label: {
                    Label("Add your first account", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: 280)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Skip for now", action: onSkip)
                    .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Step 2

    private var featuresStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Optional features")
                    .font(.system(size: 20, weight: .semibold))
                Text("Pick what you want now — everything is in Settings later too.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                featureToggle(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Auto-swap",
                    blurb: "Switch accounts automatically when quota is near limit.",
                    isOn: $optAutoSwap
                )
                featureToggle(
                    icon: "arrow.clockwise",
                    title: "Reload IDE after swap",
                    blurb: "Restarts VSCode / Cursor / Windsurf so new credentials take effect.",
                    isOn: $optIDEReload
                )
                featureToggle(
                    icon: "icloud",
                    title: "Sync to iCloud",
                    blurb: "Encrypt accounts + MCP tokens to your iCloud Drive. We'll prompt for a passphrase next.",
                    isOn: $optCloudSync
                )
                featureToggle(
                    icon: "puzzlepiece.extension",
                    title: "Local MCP connectors",
                    blurb: "Optional: connect Slack / Drive / Gmail across all accounts. Tokens stay on your Mac.",
                    isOn: $optLocalMCP
                )
            }
            Spacer(minLength: 0)
            HStack {
                Button("Back") { step = .welcome }
                    .buttonStyle(.borderless)
                Spacer()
                Button {
                    applyAndFinish()
                } label: {
                    Label("Finish", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private func featureToggle(
        icon: String,
        title: String,
        blurb: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(blurb).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            PointingHandSwitch(isOn: isOn, accessibilityName: title)
        }
    }

    private func applyAndFinish() {
        // Apply the toggles users actually flipped. We don't apply
        // cloudSync / MCP side effects (passphrase, install gateway)
        // here — too aggressive — but we record the intent so the
        // matching Settings tab can highlight a banner.
        settings.autoSwapEnabled = optAutoSwap
        settings.autoReloadIDEAfterSwap = optIDEReload
        // CloudSync + Local MCP open the relevant Settings tab so the user
        // sees what they're enrolling in before any prompt fires.
        let needsCloudSync = optCloudSync
        let needsMCP = optLocalMCP
        onFinish()
        if needsCloudSync || needsMCP {
            // Open the popover so the user lands on the destination tab.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MenuBarPopoverToggle.toggle()
            }
        }
    }
}
