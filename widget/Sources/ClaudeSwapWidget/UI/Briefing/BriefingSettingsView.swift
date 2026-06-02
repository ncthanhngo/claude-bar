import SwiftUI
import Carbon.HIToolbox

/// Settings tab for Daily Briefing — schedule, hotkeys, news feeds, source health.
/// Hosted as one tab of `SettingsWindowView`.
struct BriefingSettingsView: View {
    @EnvironmentObject private var coord: BriefingCoordinator
    @ObservedObject private var settings = AppSettings.shared
    @State private var cronDraft: String = ""
    @State private var enabledDraft: Bool = true
    @State private var saveStatus: String?

    var body: some View {
        ScrollView {
            SettingsPage {
                schedSection
                promptSection
                hotkeySection
                newsSection
                actionsSection
                healthSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            syncDraftFromSchedule()
            syncTimesFromSettings()
        }
        .onChange(of: coord.schedule?.cronExpr) { _, _ in syncDraftFromSchedule() }
    }

    // MARK: - Schedule (time-of-day list)

    @State private var times: [String] = []        // ["08:00", "12:30", "17:00"]
    @State private var newTimeDraft: String = "12:00"
    @State private var showAdvancedCron: Bool = false

    @ViewBuilder private var schedSection: some View {
        SettingsGroup(
            "Daily schedule",
            subtitle: "Add times of day for the briefing to run automatically. Each run takes ~30s."
        ) {
            // Chip list of existing times
            if !times.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(times, id: \.self) { t in
                        timeChip(t)
                    }
                }
            } else {
                Text("No times yet — add one below.")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                TextField("HH:mm", text: $newTimeDraft)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button("Add time") { addTime() }
                    .disabled(!isValidTime(newTimeDraft) || times.contains(newTimeDraft))
                Spacer()
            }

            Toggle("Enable automatic scheduler", isOn: $enabledDraft)

            DisclosureGroup("Edit cron manually (advanced)", isExpanded: $showAdvancedCron) {
                HStack {
                    Text("Cron").frame(width: 40, alignment: .leading)
                    TextField("0 8,12,17 * * *", text: $cronDraft)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.top, 4)
            }
            .font(.caption)

            HStack {
                Button("Save schedule") { saveSchedule() }
                    .disabled(times.isEmpty && cronDraft.isEmpty)
                if let s = saveStatus {
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let sched = coord.schedule {
                Text("Current: `\(sched.cronExpr)` · \(sched.enabled ? "enabled" : "disabled")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func timeChip(_ t: String) -> some View {
        HStack(spacing: 4) {
            Text(t).font(.system(.body, design: .monospaced))
            Button {
                times.removeAll(where: { $0 == t })
                persistTimes()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12))
        .clipShape(Capsule())
    }

    // MARK: - User markdown prompt

    @ViewBuilder private var promptSection: some View {
        SettingsGroup(
            "Priorities for Claude (markdown)",
            subtitle: "Describe what you care about so Claude ranks actions accordingly. Example: \"focus on engineering, skip marketing\", or a list of priority projects."
        ) {
            TextEditor(text: $settings.briefingUserPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120, maxHeight: 220)
                .padding(6)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: settings.briefingUserPrompt) { _, newValue in
                    BriefingUserPromptWriter.write(newValue)
                }

            Text("Auto-saves as you type. Every Daily run injects this text into Claude's prompt.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Schedule helpers

    private func syncTimesFromSettings() {
        // Persist file on app launch in case Settings was never opened yet
        // but the user already typed something on a prior version.
        BriefingUserPromptWriter.write(settings.briefingUserPrompt)
        let raw = settings.briefingScheduleTimes
        times = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { isValidTime($0) }
            .sorted()
    }

    private func persistTimes() {
        times.sort()
        settings.briefingScheduleTimes = times.joined(separator: ",")
        if !times.isEmpty {
            cronDraft = cronFromTimes(times)
        }
    }

    private func addTime() {
        let t = newTimeDraft.trimmingCharacters(in: .whitespaces)
        guard isValidTime(t), !times.contains(t) else { return }
        times.append(t)
        persistTimes()
        newTimeDraft = "12:00"
    }

    private func isValidTime(_ s: String) -> Bool {
        let parts = s.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), (0...23).contains(h),
              let m = Int(parts[1]), (0...59).contains(m) else {
            return false
        }
        return true
    }

    /// Convert ["08:00","12:30","17:00"] to cron. When all times share the
    /// same minute we use the compact "0 8,12,17 * * *" form; otherwise we
    /// fall back to multiple OR'd entries (rare for HH:mm picks).
    private func cronFromTimes(_ ts: [String]) -> String {
        let pairs = ts.compactMap { t -> (Int, Int)? in
            let p = t.split(separator: ":")
            guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
            return (h, m)
        }
        let minutes = Set(pairs.map(\.1))
        if minutes.count == 1, let m = minutes.first {
            let hours = pairs.map(\.0).sorted().map(String.init).joined(separator: ",")
            return "\(m) \(hours) * * *"
        }
        // Different minutes per time → list "M H" sub-expressions; some cron
        // engines support `0 8 * * *,30 12 * * *` but to stay safe we just
        // pick the first time and warn via saveStatus.
        let (h, m) = pairs.first ?? (8, 33)
        return "\(m) \(h) * * *"
    }

    private func saveSchedule() {
        let cron: String
        if !times.isEmpty {
            cron = cronFromTimes(times)
            cronDraft = cron
        } else {
            cron = cronDraft
        }
        let mixed = Set(times.compactMap { t -> Int? in
            let p = t.split(separator: ":"); return p.count == 2 ? Int(p[1]) : nil
        }).count > 1
        Task {
            await coord.saveSchedule(cron: cron, enabled: enabledDraft)
            saveStatus = coord.lastError ?? (mixed
                ? "Saved — note: the simple cron form only keeps the first time when minutes differ."
                : "Saved.")
        }
    }

    // MARK: - Hotkeys

    @ViewBuilder private var hotkeySection: some View {
        SettingsGroup("Hotkey") {
            hotkeyRow(
                title: "Open Claude Bar",
                keyCode: $settings.briefingHotkeyOpenAppKeyCode,
                modifiers: $settings.briefingHotkeyOpenAppModifiers
            )
            hotkeyRow(
                title: "Open Daily Briefing",
                keyCode: $settings.briefingHotkeyOpenBriefingKeyCode,
                modifiers: $settings.briefingHotkeyOpenBriefingModifiers
            )
            Text("ESC inside the briefing window closes it. Click 'Apply' after changes.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Apply hotkeys") { applyHotkeys() }
        }
    }

    // MARK: - News

    @ViewBuilder private var newsSection: some View {
        SettingsGroup(
            "News (optional)",
            subtitle: "'AI summary' mode: Claude opens the URL and writes a summary instead of pulling RSS."
        ) {
            HStack {
                Text("Daily fetch time")
                TextField("08:00", text: $settings.briefingNewsFetchTime)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                Stepper(value: $settings.briefingNewsFetchesPerDay, in: 1...6) {
                    Text("\(settings.briefingNewsFetchesPerDay)x per day")
                }
            }
            Divider()
            Text("Feeds").font(.subheadline.bold())
            NewsFeedsEditor()
        }
    }

    // MARK: - Actions & health

    @ViewBuilder private var actionsSection: some View {
        SettingsGroup("Actions") {
            HStack(spacing: 10) {
                Button("Run briefing now") {
                    Task { await coord.runNow() }
                }
                .disabled(coord.isRunning)
                Button("Open briefing window") { coord.show() }
                if coord.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Generating…").font(.caption)
                }
            }
            if let err = coord.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var healthSection: some View {
        SettingsGroup("Source status") {
            if let b = coord.briefing {
                ForEach(Array(b.sourcesHealth.keys.sorted()), id: \.self) { key in
                    HStack {
                        Text(key.capitalized)
                        Spacer()
                        healthBadge(b.sourcesHealth[key] ?? "—")
                    }
                }
            } else {
                Text("No briefing yet — click 'Run briefing now'.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func hotkeyRow(title: String, keyCode: Binding<Int>, modifiers: Binding<Int>) -> some View {
        HStack {
            Text(title).frame(width: 170, alignment: .leading)
            Text(hotkeyLabel(keyCode: UInt32(keyCode.wrappedValue),
                             modifiers: UInt32(modifiers.wrappedValue)))
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12)))
            Spacer()
            keyPicker(keyCode: keyCode)
            modifierMenu(modifiers: modifiers)
        }
    }

    @ViewBuilder
    private func keyPicker(keyCode: Binding<Int>) -> some View {
        Picker("", selection: keyCode) {
            ForEach(letterKeyCodes(), id: \.code) { item in
                Text(item.label).tag(item.code)
            }
        }
        .labelsHidden()
        .frame(width: 70)
    }

    @ViewBuilder
    private func modifierMenu(modifiers: Binding<Int>) -> some View {
        Menu(modifierSummary(modifiers.wrappedValue)) {
            modifierToggle(label: "⌘ Cmd",     mask: cmdKey,     binding: modifiers)
            modifierToggle(label: "⌥ Option",  mask: optionKey,  binding: modifiers)
            modifierToggle(label: "⌃ Control", mask: controlKey, binding: modifiers)
            modifierToggle(label: "⇧ Shift",   mask: shiftKey,   binding: modifiers)
        }
        .frame(width: 150)
    }

    @ViewBuilder
    private func modifierToggle(label: String, mask: Int, binding: Binding<Int>) -> some View {
        Button {
            binding.wrappedValue ^= mask
        } label: {
            HStack {
                Image(systemName: (binding.wrappedValue & mask) != 0 ? "checkmark.square.fill" : "square")
                Text(label)
            }
        }
    }

    @ViewBuilder
    private func healthBadge(_ state: String) -> some View {
        let (color, label): (Color, String) = {
            switch state {
            case "ok":           return (.green, "OK")
            case "down":         return (.red, "Down")
            case "unauthorized": return (.orange, "Not authorized")
            case "disabled":     return (.gray, "Disabled")
            default:             return (.secondary, state)
            }
        }()
        Text(label).font(.caption2).foregroundColor(.white)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(color))
    }

    private func modifierSummary(_ m: Int) -> String {
        var parts: [String] = []
        if m & controlKey != 0 { parts.append("⌃") }
        if m & optionKey  != 0 { parts.append("⌥") }
        if m & shiftKey   != 0 { parts.append("⇧") }
        if m & cmdKey     != 0 { parts.append("⌘") }
        return parts.isEmpty ? "Choose modifier…" : parts.joined()
    }

    private func syncDraftFromSchedule() {
        guard let s = coord.schedule else { return }
        cronDraft = s.cronExpr
        enabledDraft = s.enabled
    }

    private func applyHotkeys() {
        HotkeyRegistry.shared.register(
            name: BriefingHotkeySlot.openApp,
            keyCode: UInt32(settings.briefingHotkeyOpenAppKeyCode),
            modifiers: UInt32(settings.briefingHotkeyOpenAppModifiers)
        ) { MenuBarPopoverToggle.toggle() }

        HotkeyRegistry.shared.register(
            name: BriefingHotkeySlot.openBriefing,
            keyCode: UInt32(settings.briefingHotkeyOpenBriefingKeyCode),
            modifiers: UInt32(settings.briefingHotkeyOpenBriefingModifiers)
        ) { BriefingCoordinator.shared?.toggle() }
    }
}

// MARK: - Letter key catalog

private struct KeyItem { let code: Int; let label: String }

private func letterKeyCodes() -> [KeyItem] {
    [
        KeyItem(code: kVK_ANSI_A, label: "A"), KeyItem(code: kVK_ANSI_B, label: "B"),
        KeyItem(code: kVK_ANSI_C, label: "C"), KeyItem(code: kVK_ANSI_D, label: "D"),
        KeyItem(code: kVK_ANSI_E, label: "E"), KeyItem(code: kVK_ANSI_F, label: "F"),
        KeyItem(code: kVK_ANSI_G, label: "G"), KeyItem(code: kVK_ANSI_H, label: "H"),
        KeyItem(code: kVK_ANSI_I, label: "I"), KeyItem(code: kVK_ANSI_J, label: "J"),
        KeyItem(code: kVK_ANSI_K, label: "K"), KeyItem(code: kVK_ANSI_L, label: "L"),
        KeyItem(code: kVK_ANSI_M, label: "M"), KeyItem(code: kVK_ANSI_N, label: "N"),
        KeyItem(code: kVK_ANSI_O, label: "O"), KeyItem(code: kVK_ANSI_P, label: "P"),
        KeyItem(code: kVK_ANSI_Q, label: "Q"), KeyItem(code: kVK_ANSI_R, label: "R"),
        KeyItem(code: kVK_ANSI_S, label: "S"), KeyItem(code: kVK_ANSI_T, label: "T"),
        KeyItem(code: kVK_ANSI_U, label: "U"), KeyItem(code: kVK_ANSI_V, label: "V"),
        KeyItem(code: kVK_ANSI_W, label: "W"), KeyItem(code: kVK_ANSI_X, label: "X"),
        KeyItem(code: kVK_ANSI_Y, label: "Y"), KeyItem(code: kVK_ANSI_Z, label: "Z"),
    ]
}
