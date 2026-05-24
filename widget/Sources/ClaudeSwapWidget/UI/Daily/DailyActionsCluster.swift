import SwiftUI

/// Right-side actions in the Daily top bar. Mode-aware:
/// - Plan: telegram pill + Cài đặt + Chạy lại + Đóng
/// - Chat: Cài đặt + Đóng (composer + new chat handled by `DailyChatSubBar`)
struct DailyActionsCluster: View {
    let palette: BriefingPalette
    let mode: DailyMode
    let isRunning: Bool
    let onRun: () -> Void
    let onSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if mode == .plan || mode == .command {
                telegramPill
            }
            ghostButton("Cài đặt", action: onSettings)
            if mode == .plan || mode == .command {
                primaryButton(isRunning ? "Đang chạy…" : "Chạy lại", action: onRun)
                    .disabled(isRunning)
            }
            closeButton
        }
    }

    @ViewBuilder private var telegramPill: some View {
        HStack(spacing: 6) {
            Circle().fill(palette.sage).frame(width: 6, height: 6)
            Text("bot Telegram đang nghe")
                .font(.system(size: 11.5))
                .foregroundColor(palette.ink2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(palette.raisedSurface))
        .overlay(Capsule().stroke(palette.line, lineWidth: 1))
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

    @ViewBuilder private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(palette.paper)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(palette.ink))
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
