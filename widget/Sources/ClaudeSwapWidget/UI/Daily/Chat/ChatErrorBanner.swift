import SwiftUI

/// Red banner above the composer surfacing `chatStore.lastError`. The user
/// can dismiss it (clears lastError) or hit Retry — retry resends the last
/// user message text from the local optimistic bubble.
struct ChatErrorBanner: View {
    @EnvironmentObject private var chatStore: ChatStore
    let palette: BriefingPalette
    let onRetry: () -> Void

    var body: some View {
        if let err = chatStore.lastError {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(palette.coral)
                Text(err)
                    .font(.system(size: 12))
                    .foregroundColor(palette.ink)
                    .lineLimit(2)
                Spacer(minLength: 6)
                Button("Thử lại", action: onRetry)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(palette.coral)
                Button {
                    chatStore.dismissError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(palette.ink3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(palette.blush)
            .overlay(
                RoundedRectangle(cornerRadius: 10).stroke(palette.coral.opacity(0.4), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
