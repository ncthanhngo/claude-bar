import SwiftUI

/// Settings → General. Cosmetic-only basics that change how the menu-bar
/// surface *looks*. Account enrollment, IDE/terminal workflows, and
/// refresh tuning live on their own tabs so each surface stays focused on
/// one decision the user is making.
struct GeneralTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showAdvanced = false

    var body: some View {
        ScrollView {
            SettingsPage {
                SettingsGroup("Menu bar") {
                    Picker("Display style", selection: $settings.menuBarStyle) {
                        ForEach(MenuBarStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .frame(maxWidth: 360, alignment: .leading)
                    Divider()
                    iconColorPicker
                }

                SettingsGroup("Popover layout", subtitle: "Choose how much information the menu-bar popover shows. The popover auto-opens when you pick a layout so you can preview the result.") {
                    Picker("Layout", selection: $settings.popoverLayout) {
                        ForEach(PopoverLayout.allCases) { layout in
                            Text(layout.label).tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360, alignment: .leading)
                    .onChange(of: settings.popoverLayout) { _, _ in
                        // Settings lives in its own NSWindow; clicking a
                        // segment steals key focus from the popover, which
                        // dismisses on focus loss. Reopen after a short
                        // delay so the dismissal settles first, otherwise
                        // performClick would arrive while SwiftUI's
                        // "popover is shown" flag is still mid-transition
                        // and the click would silently no-op.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            MenuBarPopoverToggle.openIfClosedAbove()
                        }
                    }
                    Text(settings.popoverLayout.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Full-layout-only toggle. Hidden on Standard / Tiny
                    // because those layouts don't render the token chart
                    // at all — showing the switch there would mislead.
                    if settings.popoverLayout == .full {
                        Divider()
                        Toggle("Show token usage chart in Full layout",
                               isOn: $settings.showTokenUsageInFullPopover)
                            .onChange(of: settings.showTokenUsageInFullPopover) { _, _ in
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                    MenuBarPopoverToggle.openIfClosedAbove()
                                }
                            }
                        Text("Off by default — the chart adds ~220pt of height. Turn on to see daily/weekly/monthly token totals at a glance.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                autoRecoveryGroup

                // Adaptive-refresh is power-user-only — most people never
                // tweak it. Tuck behind a disclosure so the General page
                // doesn't open with three steppers competing for attention
                // alongside the cosmetic pickers above.
                advancedGroup
            }
        }
    }

    private var iconColorPicker: some View {
        HStack(spacing: 0) {
            Text("Icon color")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Spacer()
            HStack(spacing: 5) {
                ForEach(MenuBarIconColor.allCases) { c in
                    Button {
                        settings.menuBarIconColor = c
                    } label: {
                        ZStack {
                            if c == .system {
                                Circle()
                                    .fill(LinearGradient(
                                        colors: [.black, .white],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ))
                                    .frame(width: 18, height: 18)
                            } else {
                                Circle()
                                    .fill(c.color ?? .primary)
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                            }
                            if settings.menuBarIconColor == c {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(c == .white || c == .yellow ? .black : .white)
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .help(c.label)
                }
            }
        }
    }

    @ViewBuilder
    private var autoRecoveryGroup: some View {
        SettingsGroup("Auto-recovery", subtitle: "When the active account's login expires, Claude Bar can recover it automatically — switch to a healthy account (and silently repair the broken one) or sign back in for you in the background.") {
            Toggle("Recover dead logins automatically", isOn: $settings.autoRecoverEnabled)
            if settings.autoRecoverEnabled {
                Divider()
                Stepper(value: $settings.credSwapDelaySec, in: 0...30, step: 1) {
                    valueRow(title: "Wait before swapping", value: formatSec(settings.credSwapDelaySec))
                }
                Stepper(value: $settings.credReloginDelaySec, in: 0...60, step: 1) {
                    valueRow(title: "Wait before re-login", value: formatSec(settings.credReloginDelaySec))
                }
                Text("A notification appears first with a Cancel button, so an unwanted recovery can be stopped during the wait.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var advancedGroup: some View {
        SettingsGroup("Advanced") {
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("The widget refreshes faster when the active 5-hour usage approaches the auto-swap threshold.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    refreshStepper(
                        title: "Normal refresh",
                        value: $settings.refreshIntervalSec,
                        range: 30...900,
                        step: 30,
                        detail: "When 5h usage is below \(settings.adaptiveHighThresholdPct)%"
                    )
                    refreshStepper(
                        title: "Fast refresh",
                        value: $settings.refreshIntervalHighSec,
                        range: 30...600,
                        step: 30,
                        detail: "When 5h usage is \(settings.adaptiveHighThresholdPct)% or higher"
                    )
                    Stepper(value: $settings.adaptiveHighThresholdPct, in: 50...95, step: 5) {
                        valueRow(title: "Fast refresh starts at", value: "\(settings.adaptiveHighThresholdPct)%")
                    }
                    Divider().padding(.vertical, 4)
                    Toggle(isOn: $settings.popoverBoostEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Boost refresh when popover is open")
                            Text("Triggers an immediate refresh on open and shortens the poll cadence for ~5 minutes. Turn off on battery or metered connections — background polling keeps following the interval above.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Toggle(isOn: $settings.cookieKeepAliveEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep web session cookies fresh")
                            Text("Every few hours, pings claude.ai for any web-linked account quiet for >20h so its session cookie doesn't lapse. Skips accounts in rate-limit backoff. Safe to turn off if you don't link web profiles.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Adaptive refresh")
                    .font(.system(size: 13, weight: .medium))
            }
        }
    }

    private func refreshStepper(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        detail: String
    ) -> some View {
        Stepper(value: value, in: range, step: step) {
            VStack(alignment: .leading, spacing: 2) {
                valueRow(title: title, value: formatSec(value.wrappedValue))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func valueRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .fontWeight(.medium)
                .foregroundColor(.accentColor)
        }
    }

    private func formatSec(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if remainder == 0 { return "\(minutes)m" }
        return "\(minutes)m \(remainder)s"
    }
}
