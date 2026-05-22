import SwiftUI

/// Settings tab for the Daily Briefing — schedule, hotkey hint, manual actions.
/// Hosted as one of the `TabView` tabs in `SettingsWindowView`.
struct BriefingSettingsView: View {
    @EnvironmentObject private var coord: BriefingCoordinator
    @State private var cronDraft: String = ""
    @State private var enabledDraft: Bool = true
    @State private var saveStatus: String?

    var body: some View {
        Form {
            Section("Lịch chạy hàng ngày") {
                TextField("Cron (5 trường, giờ địa phương)", text: $cronDraft)
                    .font(.system(.body, design: .monospaced))
                Toggle("Bật scheduler tự động", isOn: $enabledDraft)
                HStack {
                    Button("Lưu") {
                        Task {
                            await coord.saveSchedule(cron: cronDraft, enabled: enabledDraft)
                            saveStatus = coord.lastError ?? "Đã lưu."
                        }
                    }
                    .disabled(cronDraft.isEmpty)
                    if let s = saveStatus {
                        Text(s).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let sched = coord.schedule {
                    Text("Hiện tại: `\(sched.cronExpr)` · \(sched.enabled ? "đang bật" : "đã tắt")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Hotkey") {
                LabeledContent("Mở briefing") {
                    Text("⌃ ⌥ ⌘ B")
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))
                        )
                }
                Text("Cố định trong MVP. Tùy chỉnh sẽ được thêm trong bản kế tiếp.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Hành động") {
                HStack(spacing: 10) {
                    Button("Chạy briefing ngay") {
                        Task { await coord.runNow() }
                    }
                    .disabled(coord.isRunning)
                    Button("Mở cửa sổ briefing") {
                        coord.show()
                    }
                }
                if coord.isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Đang tổng hợp dữ liệu…").font(.caption)
                    }
                }
                if let err = coord.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Trạng thái nguồn") {
                if let b = coord.briefing {
                    ForEach(Array(b.sourcesHealth.keys.sorted()), id: \.self) { key in
                        HStack {
                            Text(key.capitalized)
                            Spacer()
                            healthBadge(b.sourcesHealth[key] ?? "—")
                        }
                    }
                } else {
                    Text("Chưa có briefing nào — bấm 'Chạy briefing ngay'.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 520)
        .task { syncDraftFromSchedule() }
        .onChange(of: coord.schedule?.cronExpr) { _, _ in syncDraftFromSchedule() }
    }

    @ViewBuilder private func healthBadge(_ state: String) -> some View {
        let (color, label): (Color, String) = {
            switch state {
            case "ok":           return (.green, "OK")
            case "down":         return (.red, "Down")
            case "unauthorized": return (.orange, "Chưa cấp quyền")
            case "disabled":     return (.gray, "Tắt")
            default:             return (.secondary, state)
            }
        }()
        Text(label)
            .font(.caption2)
            .foregroundColor(.white)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(color))
    }

    private func syncDraftFromSchedule() {
        guard let s = coord.schedule else { return }
        cronDraft = s.cronExpr
        enabledDraft = s.enabled
    }
}
