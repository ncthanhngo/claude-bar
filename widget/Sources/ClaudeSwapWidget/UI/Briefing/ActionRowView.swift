import SwiftUI

/// One row in the daily action list: serif number + body + deadline column.
/// Mirrors `.action` styling in daily-briefing-preview.html.
struct ActionRowView: View {
    let action: ActionDTO
    let palette: BriefingPalette
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            numberLabel
            bodyColumn
            deadlineColumn
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 4)
        .overlay(Divider().background(palette.line), alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onToggle() }
    }

    @ViewBuilder private var numberLabel: some View {
        Text(action.done ? "✓" : String(format: "%02d", action.index))
            .font(.system(size: 22, weight: .light, design: .serif).italic())
            .foregroundColor(numberColor)
            .frame(width: 36, alignment: .leading)
    }

    @ViewBuilder private var bodyColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(action.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(action.done ? palette.ink3 : palette.ink)
                .strikethrough(action.done, color: palette.sage)
            HStack(spacing: 8) {
                sourceChip
                if !action.context.isEmpty {
                    Text("— " + action.context)
                        .italic()
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(palette.ink2)
                        .font(.system(size: 11.5))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var deadlineColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(action.deadline)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(deadlineColor)
            if !action.deadlineHint.isEmpty {
                Text(action.deadlineHint)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(palette.ink3)
            }
        }
        .frame(minWidth: 92, alignment: .trailing)
        .padding(.top, 2)
    }

    @ViewBuilder private var sourceChip: some View {
        Text(action.sourceMeta.isEmpty ? sourceFallback : action.sourceMeta)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundColor(sourceColor)
            .background(
                RoundedRectangle(cornerRadius: 999)
                    .fill(sourceBackground)
            )
    }

    // MARK: - Tokens

    private var numberColor: Color {
        if action.done { return palette.sage }
        switch action.priority {
        case .urgent:    return palette.coral
        case .important: return palette.rose
        case .normal:    return palette.ink3
        }
    }

    private var deadlineColor: Color {
        switch action.deadlineTone {
        case .urgent:  return palette.coral
        case .soon:    return palette.gold
        case .done:    return palette.sage
        case .normal:  return palette.ink3
        }
    }

    private var sourceColor: Color {
        switch action.source {
        case .email: return palette.coral
        case .task:  return palette.plum
        case .slack: return palette.gold
        case .meet:  return palette.moss
        }
    }

    private var sourceBackground: Color {
        switch action.source {
        case .email: return palette.cream
        case .task:  return Color(hex: 0xFBEEF2)
        case .slack: return Color(hex: 0xFDF4E9)
        case .meet:  return Color(hex: 0xEEF3EE)
        }
    }

    private var sourceFallback: String {
        switch action.source {
        case .email: return "✉ email"
        case .task:  return "◐ task"
        case .slack: return "◈ slack"
        case .meet:  return "◇ lịch"
        }
    }
}
