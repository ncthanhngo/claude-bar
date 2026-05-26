import SwiftUI

/// Right-side actions in the Daily top bar. Chat-only build: just settings
/// + close. The plan/command run controls were removed with the briefing
/// surface.
struct DailyActionsCluster: View {
    let palette: BriefingPalette
    let mode: DailyMode
    let isRunning: Bool
    let onRun: () -> Void
    let onSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ghostButton("Cài đặt", action: onSettings)
            closeButton
        }
    }

    @ViewBuilder private func ghostButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(palette.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(Color.white))
        .overlay(Capsule().stroke(palette.line, lineWidth: 1))
    }

    @ViewBuilder private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(palette.ink2)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .background(Circle().fill(palette.raisedSurface))
        .overlay(Circle().stroke(palette.line, lineWidth: 1))
    }
}
