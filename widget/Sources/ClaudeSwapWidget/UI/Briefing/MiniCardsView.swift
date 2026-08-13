import SwiftUI

/// Stub "Tin công nghệ" + "Bot Telegram" cards in the right column.
/// Both are post-MVP — render as opt-in placeholders that preserve layout.
struct MiniNewsCard: View {
    let palette: BriefingPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline) {
                Text("Tin đáng đọc")
                    .font(.system(size: 14, weight: .medium, design: .serif).italic())
                    .foregroundColor(palette.ink)
                Spacer()
                Text("TÙY CHỌN")
                    .font(.system(size: 10.5)).kerning(1.5)
                    .foregroundColor(palette.ink3)
            }
            Text("Bật trong Cài đặt → Tin tức để chọn nguồn & chủ đề (AI, Frontend, Security…)")
                .font(.system(size: 12.5))
                .foregroundColor(palette.ink2)
                .lineSpacing(2)
            HStack(spacing: 6) {
                chip("AI/LLM")
                chip("Frontend")
                chip("DevOps")
                chip("Security")
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(cardBackground(palette))
    }

    @ViewBuilder private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundColor(palette.plum)
            .background(Capsule().fill(palette.cream))
    }
}

struct MiniTelegramCard: View {
    let palette: BriefingPalette
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline) {
                Text("Bot Telegram")
                    .font(.system(size: 14, weight: .medium, design: .serif).italic())
                    .foregroundColor(palette.ink)
                Spacer()
                Text("@DAILY_BRIEFING_BOT")
                    .font(.system(size: 10.5)).kerning(1.5)
                    .foregroundColor(palette.ink3)
            }
            Text("Hỏi nhanh briefing qua chat — gửi /today, /snooze 1h.")
                .font(.system(size: 12.5))
                .foregroundColor(palette.ink2)
                .lineSpacing(2)
            HStack(spacing: 5) {
                ForEach(["/today", "/week", "/news", "/run"], id: \.self) { cmd in
                    Text(cmd)
                        .font(.system(size: 10.5, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundColor(palette.ink2)
                        .background(Capsule().fill(palette.raisedSurface))
                        .overlay(Capsule().stroke(palette.line, lineWidth: 1))
                }
            }
            HStack {
                TextField("hỏi bot một câu...", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundColor(palette.ink)
                Button { draft = "" } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(palette.coral))
                }
                .buttonStyle(.plain)
                .disabled(true)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(palette.cream)
            )
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(cardBackground(palette))
    }
}

private func cardBackground(_ p: BriefingPalette) -> some View {
    RoundedRectangle(cornerRadius: 16)
        .fill(p.raisedSurface)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(p.line, lineWidth: 1))
        .shadow(color: p.cardShadow, radius: 12, x: 0, y: 6)
}

struct BriefingFooterTickerView: View {
    let palette: BriefingPalette
    let sourcesCount: Int

    var body: some View {
        HStack {
            Text("\(sourcesCount) nguồn · Gmail · Calendar · ClickUp · Slack")
                .foregroundColor(palette.ink3)
            Spacer()
            HStack(spacing: 8) {
                Text("theme ·")
                Text("nhẹ ấm").fontWeight(.medium).foregroundColor(palette.ink2)
                Text("⌘ K")
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4).fill(Color.white)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.line, lineWidth: 1))
                Text("tìm việc")
            }
        }
        .font(.system(size: 11))
        .foregroundColor(palette.ink3)
        .padding(.top, 10)
        .overlay(Divider().background(palette.line), alignment: .top)
    }
}
