import SwiftUI

/// Root view of the Daily window. Composition only — actual content lives in
/// `DailyTopBar`, `PlanModeBody`, `ChatModeBody`. Plan and Chat bodies are
/// kept alive simultaneously via opacity so a mode flip doesn't trigger an
/// expensive briefing re-fetch.
struct BriefingView: View {
    @EnvironmentObject private var coord: BriefingCoordinator
    @ObservedObject private var settings = AppSettings.shared

    private var palette: BriefingPalette { settings.widgetTheme.briefingPalette }

    private var modeBinding: Binding<DailyMode> {
        Binding(
            get: { DailyMode.from(settings.dailyMode) },
            set: { settings.dailyMode = $0.rawValue }
        )
    }

    var body: some View {
        ZStack {
            backgroundLayer.ignoresSafeArea()
            VStack(spacing: 16) {
                DailyTopBar(
                    mode: modeBinding,
                    palette: palette,
                    dateLabel: dateLabel,
                    lastGenerated: lastGeneratedLabel,
                    nextRun: nextRunLabel,
                    isRunning: coord.isRunning,
                    onRun: { Task { await coord.runNow() } },
                    onNewChat: { /* Phase 06+ wires ChatStore.newConversation() */ },
                    onSettings: { NotificationCenter.default.post(name: .openSettings, object: nil) },
                    onClose: { coord.close() }
                )
                bodyStage
            }
            .padding(EdgeInsets(top: 22, leading: 28, bottom: 22, trailing: 28))

            hiddenShortcuts
        }
        .frame(minWidth: 1280, minHeight: 800)
    }

    @ViewBuilder private var bodyStage: some View {
        let mode = DailyMode.from(settings.dailyMode)
        ZStack {
            PlanModeBody(palette: palette)
                .opacity(mode == .plan ? 1 : 0)
                .allowsHitTesting(mode == .plan)
            ChatModeBody(palette: palette)
                .opacity(mode == .chat ? 1 : 0)
                .allowsHitTesting(mode == .chat)
        }
        .animation(.easeInOut(duration: 0.18), value: mode)
    }

    @ViewBuilder private var hiddenShortcuts: some View {
        // ESC closes; ⌘1 / ⌘2 swap the body mode. Buttons are invisible —
        // SwiftUI only needs them in the hierarchy for the shortcut to bind.
        Group {
            Button("") { coord.close() }
                .keyboardShortcut(.cancelAction)
            Button("") { settings.dailyMode = DailyMode.plan.rawValue }
                .keyboardShortcut("1", modifiers: .command)
            Button("") { settings.dailyMode = DailyMode.chat.rawValue }
                .keyboardShortcut("2", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var backgroundLayer: some View {
        ZStack {
            palette.paper
            RadialGradient(
                colors: [palette.rose.opacity(0.08), .clear],
                center: .topLeading, startRadius: 0, endRadius: 700
            )
            RadialGradient(
                colors: [palette.sage.opacity(0.07), .clear],
                center: .topTrailing, startRadius: 0, endRadius: 700
            )
        }
    }

    // MARK: - Labels

    private var dateLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = "EEEE · d / M"
        return f.string(from: Date()).capitalized
    }

    private var lastGeneratedLabel: String {
        guard let b = coord.briefing else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = "HH:mm 'sáng'"
        return f.string(from: b.generatedAt)
    }

    private var nextRunLabel: String {
        guard let s = coord.schedule, !s.cronExpr.isEmpty else { return "—" }
        return "08:33 mai"
    }
}
