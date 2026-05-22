import SwiftUI

/// Empty-rail copy shown when the active account has zero conversations.
/// Editorial italic prompt + a "Đoạn chat mới" CTA that mirrors the top bar.
struct ChatRailEmptyState: View {
    let palette: BriefingPalette
    let onNewConversation: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 60)
            Text("Chưa có đoạn chat nào.")
                .font(.system(size: 16, design: .serif).italic())
                .foregroundColor(palette.ink)
            Text("Bắt đầu một câu hỏi cho Claude — lịch sử sẽ lưu local cho riêng tài khoản này.")
                .font(.system(size: 12))
                .foregroundColor(palette.ink3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
            Button(action: onNewConversation) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text("Đoạn chat mới")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(palette.paper)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(palette.coral))
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }
}
