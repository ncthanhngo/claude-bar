import SwiftUI

/// Top-of-PLAN strip showing the six MCP source connectors with last-sync
/// status. Reads `BriefingDTO.sourcesHealth` (map of source name → "ok" |
/// "warn" | "fail") so the dot color reflects real adapter state.
///
/// Sources we surface (matches the preview HTML): Calendar / Gmail / Drive
/// / Slack / ClickUp / RSS. Anything else in sourcesHealth is ignored.
struct PlanMCPSourceBar: View {
    let sourcesHealth: [String: String]
    let lastUpdatedLabel: String
    let palette: BriefingPalette

    var body: some View {
        HStack(spacing: 8) {
            Text("Nguồn MCP")
                .font(.system(size: 10.5, weight: .bold))
                .kerning(2.0)
                .foregroundColor(palette.ink3)
                .textCase(.uppercase)
            ForEach(catalog, id: \.name) { spec in
                sourcePill(spec)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(palette.sage)
                    .frame(width: 6, height: 6)
                Text("cập nhật \(lastUpdatedLabel)")
                    .font(.system(size: 11))
                    .foregroundColor(palette.ink3)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(palette.paper)
        .overlay(Divider().background(palette.line), alignment: .bottom)
    }

    @ViewBuilder private func sourcePill(_ spec: MCPSourceSpec) -> some View {
        HStack(spacing: 6) {
            iconBadge(spec.shortLabel, color: spec.color)
            Text(spec.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(palette.ink2)
            Circle()
                .fill(statusColor(for: spec.name))
                .frame(width: 5, height: 5)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(palette.paper)
        .overlay(Capsule().stroke(palette.line2, lineWidth: 1))
        .clipShape(Capsule())
        .help(statusHelp(for: spec.name))
    }

    @ViewBuilder private func iconBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .heavy))
            .foregroundColor(palette.paper)
            .frame(width: 14, height: 14)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func statusColor(for source: String) -> Color {
        switch sourcesHealth[source] {
        case "ok":     return palette.sage
        case "warn":   return palette.gold
        case "fail":   return palette.coral
        default:       return palette.line2
        }
    }

    private func statusHelp(for source: String) -> String {
        switch sourcesHealth[source] {
        case "ok":   return "\(source): kết nối tốt"
        case "warn": return "\(source): cảnh báo (xem briefing log)"
        case "fail": return "\(source): không kết nối được"
        default:     return "\(source): chưa kết nối"
        }
    }

    private var catalog: [MCPSourceSpec] {
        [
            MCPSourceSpec(name: "gcal",    displayName: "Calendar", shortLabel: "G",  color: Color(red: 0.26, green: 0.52, blue: 0.96)),
            MCPSourceSpec(name: "gmail",   displayName: "Gmail",    shortLabel: "M",  color: Color(red: 0.92, green: 0.26, blue: 0.21)),
            MCPSourceSpec(name: "gdrive",  displayName: "Drive",    shortLabel: "D",  color: Color(red: 0.00, green: 0.67, blue: 0.28)),
            MCPSourceSpec(name: "slack",   displayName: "Slack",    shortLabel: "#",  color: Color(red: 0.29, green: 0.08, blue: 0.29)),
            MCPSourceSpec(name: "clickup", displayName: "ClickUp",  shortLabel: "CU", color: Color(red: 0.48, green: 0.41, blue: 0.93)),
            MCPSourceSpec(name: "rss",     displayName: "RSS",      shortLabel: "R",  color: palette.coral),
        ]
    }
}

/// Static metadata for one MCP source pill. Name matches the key the
/// briefing backend reports in BriefingDTO.sourcesHealth.
struct MCPSourceSpec {
    let name: String
    let displayName: String
    let shortLabel: String
    let color: Color
}
