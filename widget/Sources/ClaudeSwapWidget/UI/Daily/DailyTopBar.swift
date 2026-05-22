import SwiftUI

/// Composition root for the Daily window header. Lays out brand, mode
/// switcher, mode-specific middle strip, OAuth account chip and actions.
struct DailyTopBar: View {
    @Binding var mode: DailyMode

    let palette: BriefingPalette
    let dateLabel: String
    let lastGenerated: String
    let nextRun: String
    let isRunning: Bool
    let onRun: () -> Void
    let onNewChat: () -> Void
    let onSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 22) {
            brand
            DailyModeSwitcher(mode: $mode, palette: palette)
                .padding(.leading, 4)

            Group {
                switch mode {
                case .plan:
                    DailyMetaStrip(
                        palette: palette,
                        dateLabel: dateLabel,
                        lastGenerated: lastGenerated,
                        nextRun: nextRun
                    )
                case .chat:
                    DailyChatSubBar(palette: palette, isReady: true, onNewChat: onNewChat)
                }
            }
            .padding(.leading, 6)

            Spacer(minLength: 12)

            DailyAccountChip(palette: palette)
            DailyActionsCluster(
                palette: palette,
                mode: mode,
                isRunning: isRunning,
                onRun: onRun,
                onSettings: onSettings,
                onClose: onClose
            )
        }
        .padding(.bottom, 14)
        .overlay(Divider().background(palette.line), alignment: .bottom)
    }

    @ViewBuilder private var brand: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("đẹp.")
                .font(.system(size: 28, weight: .semibold, design: .serif).italic())
                .foregroundColor(palette.coral)
            Text("DAILY · CLAUDE BAR")
                .font(.system(size: 11))
                .kerning(1.5)
                .foregroundColor(palette.ink3)
        }
    }
}
