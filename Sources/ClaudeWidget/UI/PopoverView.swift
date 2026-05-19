import SwiftUI
import AppKit

/// Slim container — composes the section views. Owns sheet-presentation state.
struct PopoverView: View {
    @ObservedObject var store: UsageStore

    @State private var showingAddAccount = false
    @State private var showingConnect = false
    @State private var showingMagicLink = false
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderBar(store: store, showingSettings: $showingSettings)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WebConnectionBanner(store: store, showingConnect: $showingConnect)
                    if let pending = store.pendingSwitch {
                        PendingSwitchBanner(pending: pending, onCancel: { store.cancelPendingSwitch() })
                    }
                    HeroCard(store: store)
                    AccountsList(store: store, showingAddAccount: $showingAddAccount)
                    AutoSwitchControl(store: store)
                    if let err = store.lastError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            Divider()
            FooterBar(store: store)
        }
        .frame(width: 380, height: 580)
        .sheet(isPresented: $showingAddAccount) {
            AddAccountSheet(
                store: store,
                isPresented: $showingAddAccount,
                onChooseMagicLink: switchToMagicLink
            )
        }
        .sheet(isPresented: $showingMagicLink) {
            MagicLinkLoginSheet(store: store, isPresented: $showingMagicLink)
        }
        .sheet(isPresented: $showingConnect) {
            ConnectClaudeAiSheet(store: store, isPresented: $showingConnect)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(store: store, isPresented: $showingSettings)
        }
    }

    /// SwiftUI sheets are exclusive — dismiss the current one first, then
    /// present the magic-link sheet on the next runloop tick.
    private func switchToMagicLink() {
        showingAddAccount = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            showingMagicLink = true
        }
    }
}

// MARK: - Header & Footer

private struct HeaderBar: View {
    @ObservedObject var store: UsageStore
    @Binding var showingSettings: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.medium")
                .foregroundStyle(.tint)
            Text("Claude Usage").font(.headline)
            Spacer()
            if store.isScanning || store.isFetchingWeb {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            } else {
                Button {
                    store.refresh()
                    store.fetchWebUsage()
                } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

private struct FooterBar: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack {
            if let active = store.activeAccount {
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text(active.displayName).font(.caption2).lineLimit(1)
                }
            } else if let date = store.lastScannedAt {
                Text("Scanned \(date, style: .time)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: { Text("Quit").font(.caption) }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
