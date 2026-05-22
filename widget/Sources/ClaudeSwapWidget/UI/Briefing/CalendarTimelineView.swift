import SwiftUI

/// Vertical timeline of today's events with state-tinted dots.
/// Mirrors `.calendar` block in the mockup.
struct CalendarTimelineView: View {
    let events: [CalEventDTO]
    let palette: BriefingPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if events.isEmpty {
                Text("Không có sự kiện hôm nay")
                    .font(.system(size: 12.5))
                    .foregroundColor(palette.ink3)
                    .padding(.top, 12)
            } else {
                ForEach(events) { event in
                    EventRow(event: event, palette: palette)
                }
            }
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(palette.raisedSurface)
                .shadow(color: palette.cardShadow, radius: 12, x: 0, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16).stroke(palette.line, lineWidth: 1)
        )
    }

    @ViewBuilder private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            Text("Lịch trong ngày")
                .font(.system(size: 18, weight: .regular, design: .serif).italic())
                .foregroundColor(palette.ink)
            Spacer()
            Text("\(events.count) sự kiện".uppercased())
                .font(.system(size: 11))
                .kerning(1.5)
                .foregroundColor(palette.ink3)
        }
        .padding(.bottom, 10)
    }
}

private struct EventRow: View {
    let event: CalEventDTO
    let palette: BriefingPalette

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            dot
                .padding(.top, 4)
            timeColumn
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(palette.ink)
                if !event.subtitle.isEmpty {
                    Text(event.subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(palette.ink3)
                }
                if let flag = event.flag, !flag.isEmpty {
                    Text(flag)
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .foregroundColor(palette.coral)
                        .background(
                            Capsule().fill(palette.blush)
                        )
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var dot: some View {
        Circle()
            .fill(dotFill)
            .frame(width: 9, height: 9)
            .overlay(
                Circle().stroke(dotStroke, lineWidth: 2)
            )
            .shadow(color: dotFill.opacity(state == .now ? 0.4 : 0), radius: 4)
    }

    @ViewBuilder private var timeColumn: some View {
        Text(event.time)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(palette.ink2)
            .frame(width: 56, alignment: .leading)
            .padding(.top, 2)
    }

    private var state: CalEventDTO.State { event.state }

    private var dotFill: Color {
        switch state {
        case .done: return palette.sage
        case .now:  return palette.coral
        case .next: return palette.raisedSurface
        }
    }
    private var dotStroke: Color {
        switch state {
        case .done: return palette.sage
        case .now:  return palette.coral
        case .next: return palette.gold
        }
    }
}
