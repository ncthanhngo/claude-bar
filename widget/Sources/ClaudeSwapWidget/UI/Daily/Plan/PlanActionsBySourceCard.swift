import SwiftUI

/// Generic MCP card that filters BriefingDTO.actions by source kind and
/// renders them as a small feed. Used three times in PLAN: Slack mentions,
/// ClickUp tasks (with due-date badge), and Gmail inbox follow-ups.
struct PlanActionsBySourceCard: View {
    enum Variant {
        case slack
        case clickup
        case email
    }

    let variant: Variant
    let actions: [ActionDTO]
    let palette: BriefingPalette

    var body: some View {
        PlanCardChrome(
            title: title,
            sourceLabel: sourceLabel,
            sourceIconLabel: sourceIcon,
            sourceIconColor: sourceColor,
            count: actions.count,
            countSuffix: countSuffix,
            palette: palette
        ) {
            if actions.isEmpty {
                Text("Không có gì đáng để ý.")
                    .font(.system(size: 12.5, design: .serif).italic())
                    .foregroundColor(palette.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(actions) { action in
                        row(action)
                    }
                }
            }
        }
    }

    @ViewBuilder private func row(_ action: ActionDTO) -> some View {
        HStack(alignment: .top, spacing: 11) {
            if variant == .clickup {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(palette.line2, lineWidth: 1.5)
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)
            } else {
                avatar(for: action)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(action.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(palette.ink)
                    .lineLimit(2)
                if !action.sourceMeta.isEmpty || !action.context.isEmpty {
                    Text(metaLine(action))
                        .font(.system(size: 11))
                        .foregroundColor(palette.ink3)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            if variant == .clickup {
                dueBadge(action)
            }
        }
        .padding(.vertical, 10)
        .overlay(Divider().background(palette.line), alignment: .top)
    }

    @ViewBuilder private func avatar(for action: ActionDTO) -> some View {
        Text(initials(action))
            .font(.system(size: 11, weight: .bold, design: .serif).italic())
            .foregroundColor(palette.ink)
            .frame(width: 28, height: 28)
            .background(Circle().fill(avatarColor(action)))
    }

    @ViewBuilder private func dueBadge(_ action: ActionDTO) -> some View {
        if action.deadline.isEmpty { EmptyView() } else {
            let (bg, fg) = duePalette(action.deadlineTone)
            Text(action.deadline)
                .font(.system(size: 10.5, weight: .bold))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundColor(fg)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(bg)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Variant config

    private var title: String {
        switch variant {
        case .slack:   return "Slack đáng để ý"
        case .clickup: return "ClickUp · sắp deadline"
        case .email:   return "Email cần reply"
        }
    }

    private var sourceLabel: String {
        switch variant {
        case .slack:   return "Slack"
        case .clickup: return "ClickUp"
        case .email:   return "Gmail"
        }
    }

    private var sourceIcon: String {
        switch variant {
        case .slack:   return "#"
        case .clickup: return "CU"
        case .email:   return "M"
        }
    }

    private var sourceColor: Color {
        switch variant {
        case .slack:   return Color(red: 0.29, green: 0.08, blue: 0.29)
        case .clickup: return Color(red: 0.48, green: 0.41, blue: 0.93)
        case .email:   return Color(red: 0.92, green: 0.26, blue: 0.21)
        }
    }

    private var countSuffix: String {
        switch variant {
        case .slack:   return "mention"
        case .clickup: return "task"
        case .email:   return "thư"
        }
    }

    // MARK: - Row helpers

    private func metaLine(_ action: ActionDTO) -> String {
        let parts = [action.sourceMeta, action.context]
            .filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    private func initials(_ action: ActionDTO) -> String {
        let trimmed = action.sourceMeta.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "?" }
        let words = trimmed.split(separator: " ").prefix(2)
        return words.map { String($0.prefix(1)).uppercased() }.joined()
    }

    private func avatarColor(_ action: ActionDTO) -> Color {
        // Stable rotation by source meta hash so the same sender always
        // gets the same chip color across renders.
        let palette: [Color] = [
            self.palette.peach,
            self.palette.blush,
            Color(red: 0.78, green: 0.87, blue: 0.76),
            Color(red: 0.86, green: 0.79, blue: 0.84),
        ]
        let bucket = abs(action.sourceMeta.hashValue) % palette.count
        return palette[bucket]
    }

    private func duePalette(_ tone: ActionDTO.DeadlineTone) -> (bg: Color, fg: Color) {
        switch tone {
        case .urgent:
            return (palette.coral, palette.paper)
        case .soon:
            return (palette.gold.opacity(0.15), palette.gold)
        case .normal, .done:
            return (palette.paper2, palette.ink2)
        }
    }
}
