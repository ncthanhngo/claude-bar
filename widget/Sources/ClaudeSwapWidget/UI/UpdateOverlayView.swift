import SwiftUI

/// In-popover overlay that renders the Sparkle update flow on top of the
/// menu-bar popover content. The overlay sits centered, dims the popover
/// behind it, and only appears while `driver.stage != .idle`.
///
/// Each `Stage` case maps to a "card" — Checking, Update found, Downloading,
/// Extracting, Ready, Installing, Up-to-date, Error. Buttons forward back to
/// the driver so the user can pick what to do, while the popover itself
/// stays open (no focus-stealing window appears).
struct UpdateOverlayView: View {
    @ObservedObject var driver: InPopoverUpdateDriver

    var body: some View {
        if driver.stage != .idle {
            ZStack {
                // Dim + click-eater behind the card so taps don't reach the
                // popover content underneath while an update is in flight.
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { /* eat */ }

                card
                    .frame(maxWidth: 380)
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.thickMaterial)
                            .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 8)
                    )
                    .padding(.horizontal, 24)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .animation(.easeOut(duration: 0.18), value: driver.stage)
        }
    }

    @ViewBuilder
    private var card: some View {
        switch driver.stage {
        case .idle:
            EmptyView()

        case .checking:
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Checking for updates…").font(.headline)
                Button("Cancel") { driver.userTappedCancelCheck() }
                    .keyboardShortcut(.cancelAction)
            }

        case let .foundUpdate(version, notes):
            VStack(alignment: .leading, spacing: 12) {
                Text("Update available")
                    .font(.title3.weight(.semibold))
                Text("Claude Bar \(version) is ready to install.")
                    .foregroundStyle(.secondary)
                if let notes, !notes.isEmpty {
                    ScrollView {
                        Text(notes)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.05))
                    )
                }
                HStack {
                    Button("Skip This Version") { driver.userTappedSkip() }
                    Spacer()
                    Button("Later") { driver.userTappedLater() }
                        .keyboardShortcut(.cancelAction)
                    Button("Install Update") { driver.userTappedInstall() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }

        case let .downloading(progress):
            VStack(spacing: 12) {
                Text("Downloading update…").font(.headline)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                HStack {
                    Spacer()
                    Button("Cancel") { driver.userTappedCancelDownload() }
                        .keyboardShortcut(.cancelAction)
                }
            }

        case let .extracting(progress):
            VStack(spacing: 12) {
                Text("Preparing update…").font(.headline)
                if progress > 0 {
                    ProgressView(value: progress).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }

        case .readyToInstall:
            VStack(alignment: .leading, spacing: 12) {
                Text("Ready to install")
                    .font(.title3.weight(.semibold))
                Text("Claude Bar will restart to finish the update.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Later") { driver.userTappedLater() }
                        .keyboardShortcut(.cancelAction)
                    Button("Install and Restart") { driver.userTappedInstall() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }

        case .installing:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Installing update…").font(.headline)
                Text("Claude Bar will restart in a moment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .upToDate:
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.green)
                Text("You're up to date")
                    .font(.title3.weight(.semibold))
                Text("Claude Bar is running the latest version.")
                    .foregroundStyle(.secondary)
                Button("OK") { driver.userTappedAcknowledge() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }

        case let .error(message):
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Update failed").font(.title3.weight(.semibold))
                }
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("OK") { driver.userTappedAcknowledge() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
