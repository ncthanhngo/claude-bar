import SwiftUI

/// Shared chrome (white card + rounded corners + soft shadow + header row)
/// used by every PLAN-mode MCP card. Keeps the visual rhythm consistent
/// across Calendar / Reading / Slack / ClickUp / Gmail cards.
struct PlanCardChrome<Content: View>: View {
    let title: String
    let sourceLabel: String
    let sourceIconLabel: String
    let sourceIconColor: Color
    let count: Int
    let countSuffix: String
    let palette: BriefingPalette
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(palette.raisedSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(palette.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: palette.cardShadow, radius: 6, x: 0, y: 1)
    }

    @ViewBuilder private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 17, design: .serif).italic())
                .foregroundColor(palette.ink)
            Spacer()
            sourceTag
            countTag
        }
    }

    @ViewBuilder private var sourceTag: some View {
        HStack(spacing: 5) {
            Text(sourceIconLabel)
                .font(.system(size: 8, weight: .heavy))
                .foregroundColor(palette.paper)
                .frame(width: 12, height: 12)
                .background(sourceIconColor)
                .clipShape(RoundedRectangle(cornerRadius: 2.5))
            Text(sourceLabel)
                .font(.system(size: 9.5, weight: .bold))
                .kerning(1.0)
                .foregroundColor(palette.ink3)
                .textCase(.uppercase)
        }
    }

    @ViewBuilder private var countTag: some View {
        Text("\(count) \(countSuffix)")
            .font(.system(size: 10, weight: .bold))
            .kerning(1.8)
            .foregroundColor(palette.ink3)
            .textCase(.uppercase)
    }
}
