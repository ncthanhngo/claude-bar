import SwiftUI

/// Editorial hero: serif eyebrow + title + count + focus banner.
/// Mirrors `.hero-head` + `.focus-banner` in the mockup.
struct HeroHeaderView: View {
    let hero: HeroDTO
    let palette: BriefingPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                titleColumn
                Spacer(minLength: 24)
                countColumn
            }
            focusBanner
        }
    }

    @ViewBuilder private var titleColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hero.eyebrow.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(2.5)
                .foregroundColor(palette.ink3)

            Text(LocalizedStringKey(hero.title))
                .font(.system(size: 56, weight: .light, design: .serif))
                .foregroundColor(palette.ink)
                .lineSpacing(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var countColumn: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(String(format: "%02d", hero.countNumber))
                .font(.system(size: 64, weight: .light, design: .serif))
                .foregroundColor(palette.ink)
                .kerning(-1)
            Text(hero.countLabel)
                .font(.system(size: 12))
                .foregroundColor(palette.ink3)
        }
    }

    @ViewBuilder private var focusBanner: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(hero.focusBadge.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(1.5)
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(palette.coral)
                )

            Text(LocalizedStringKey(hero.focusBody))
                .font(.system(size: 15, weight: .regular, design: .serif))
                .foregroundColor(palette.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            LinearGradient(
                colors: [palette.cream, palette.blush],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(palette.coral.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
