import SwiftUI

/// Placeholder for the Chat mode body. Phase 07 replaces this with the real
/// rail + thread + composer. Renders an editorial "sắp đến" notice so users
/// who toggle into Chat early still get a coherent visual.
struct ChatModeBody: View {
    let palette: BriefingPalette

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Sắp đến.")
                .font(.system(size: 56, weight: .regular, design: .serif).italic())
                .foregroundColor(palette.coral)
            Text("Đoạn chat OAuth với tài khoản active sẽ sống tại đây.\nLịch sử nằm local, mã hoá, không sync về tài khoản Claude.")
                .multilineTextAlignment(.center)
                .font(.system(size: 14))
                .foregroundColor(palette.ink2)
                .frame(maxWidth: 520)
            Rectangle()
                .fill(palette.line)
                .frame(width: 60, height: 1)
                .padding(.top, 4)
            Text("Phase 07 — Widget Chat UI (rail · thread · composer)")
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(1.6)
                .foregroundColor(palette.ink3)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
