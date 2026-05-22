import SwiftUI

/// MCP card showing today's calendar as a dot-timeline. Renders done events
/// with a filled sage dot, the current event with a pulsing coral dot, and
/// upcoming events with a hollow ring. The "now" event also gets a
/// preparation chip if the subtitle carries one ("cần chuẩn bị demo").
struct PlanCalendarCard: View {
    let events: [CalEventDTO]
    let palette: BriefingPalette

    var body: some View {
        PlanCardChrome(
            title: "Lịch trong ngày",
            sourceLabel: "Calendar",
            sourceIconLabel: "G",
            sourceIconColor: Color(red: 0.26, green: 0.52, blue: 0.96),
            count: events.count,
            countSuffix: "sự kiện",
            palette: palette
        ) {
            if events.isEmpty {
                emptyState
            } else {
                timeline
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        Text("Lịch trống.")
            .font(.system(size: 12.5, design: .serif).italic())
            .foregroundColor(palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    @ViewBuilder private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(events) { event in
                row(event)
            }
        }
    }

    @ViewBuilder private func row(_ event: CalEventDTO) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(event.time)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(palette.ink3)
                .frame(width: 48, alignment: .leading)
                .padding(.top, 2)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(palette.line)
                    .frame(width: 1)
                    .padding(.leading, 6)
                dot(for: event.state)
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(palette.ink)
                if !event.subtitle.isEmpty {
                    Text(event.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundColor(palette.ink3)
                }
                if let flag = event.flag, !flag.isEmpty {
                    Text(flag)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(palette.plum)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(palette.blush))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder private func dot(for state: CalEventDTO.State) -> some View {
        switch state {
        case .done:
            Circle()
                .fill(palette.sage)
                .frame(width: 13, height: 13)
                .overlay(Circle().stroke(palette.paper, lineWidth: 2))
        case .now:
            Circle()
                .fill(palette.coral)
                .frame(width: 13, height: 13)
                .overlay(Circle().stroke(palette.coral.opacity(0.25), lineWidth: 4))
        case .next:
            Circle()
                .strokeBorder(palette.ink3, lineWidth: 2)
                .frame(width: 13, height: 13)
                .background(Circle().fill(palette.paper))
        }
    }
}
