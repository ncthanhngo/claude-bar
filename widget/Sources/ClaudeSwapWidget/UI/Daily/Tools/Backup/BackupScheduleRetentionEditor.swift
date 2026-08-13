import SwiftUI

/// Schedule (time + cron/systemd) and grandfather-father-son retention counts.
struct BackupScheduleRetentionEditor: View {
    @Binding var profile: BackupProfile
    let palette: BriefingPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Lịch chạy & lưu giữ", systemImage: "calendar.badge.clock")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(palette.ink)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Giờ chạy (giờ server)").font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(palette.ink3)
                    TextField("02:30", text: $profile.schedule.timeOfDay)
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cơ chế").font(.system(size: 10.5, weight: .medium)).foregroundColor(palette.ink3)
                    Picker("", selection: $profile.schedule.mechanism) {
                        Text("cron").tag("cron")
                        Text("systemd").tag("systemd")
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 160)
                }
                Spacer()
            }

            Text("Số bản giữ mỗi tầng (grandfather-father-son)")
                .font(.system(size: 10.5, weight: .medium)).foregroundColor(palette.ink3)
            HStack(spacing: 14) {
                stepper("Ngày", value: $profile.retention.daily)
                stepper("Tuần", value: $profile.retention.weekly)
                stepper("Tháng", value: $profile.retention.monthly)
                stepper("Năm", value: $profile.retention.yearly)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.raisedSurface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
    }

    private func stepper(_ label: String, value: Binding<Int>) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundColor(palette.ink2)
            Stepper(value: value, in: 0...365) {
                Text("\(value.wrappedValue)").font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(palette.ink).frame(minWidth: 22)
            }.labelsHidden()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.paper2))
    }
}
