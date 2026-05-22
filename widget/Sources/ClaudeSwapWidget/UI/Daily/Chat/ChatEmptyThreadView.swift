import SwiftUI

/// Shown when an active conversation has zero messages yet. Editorial-style
/// invitation + 4 hardcoded suggestion prompts. Tapping a suggestion injects
/// the text into the composer via the binding.
struct ChatEmptyThreadView: View {
    let palette: BriefingPalette
    let onPickSuggestion: (String) -> Void

    private let suggestions: [String] = [
        "Tóm tắt lịch hôm nay theo thứ tự ưu tiên.",
        "Đề xuất câu trả lời lịch sự cho email này…",
        "Giải thích đoạn code Swift này từng dòng.",
        "Soát chính tả + giọng văn cho đoạn dưới."
    ]

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 80)
            Text("Đoạn chat mới — gõ gì đó nhé.")
                .font(.system(size: 26, design: .serif).italic())
                .foregroundColor(palette.ink)
            Text("Lịch sử lưu cục bộ, mã hoá. Không sync về tài khoản Claude.")
                .font(.system(size: 12.5))
                .foregroundColor(palette.ink3)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(suggestions, id: \.self) { s in
                    Button(action: { onPickSuggestion(s) }) {
                        Text(s)
                            .font(.system(size: 12.5, design: .serif).italic())
                            .foregroundColor(palette.ink2)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(palette.cream)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 40)

            Spacer()
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }
}
