import SwiftUI

/// Sticky glass top bar — port of the mockup's `.bar`: brand mark, the ⌥X
/// hotkey hint, the Master/Client role segmented control, the AI provider
/// picker, and a manual refresh button.
///
/// Provider/model are Go-owned config (see `NewsConfigDTO` /
/// contract.md "Config ownership split") — this view fetches the current
/// choice via `CswClient.newsConfigGet()` and persists changes via
/// `newsConfigSet()`. Both are wrapped in `try?` because the backend command
/// doesn't exist yet in Phase 1; the picker still updates locally so the
/// control feels alive, it just won't survive a relaunch until Phase 2/3
/// land the Go side.
struct NewsTopBar: View {
    @EnvironmentObject private var store: NewsStore
    @ObservedObject private var settings = AppSettings.shared
    private let client = CswClient()

    /// "provider · model" option strings shown in the picker. Seeded with a
    /// sensible static set; `loadConfig()` widens it once
    /// `newsProviders()`/`newsConfigGet()` succeed (Phase 2+).
    @State private var providerOptions: [String] = ["claude · tài khoản", "ollama · qwen2.5", "ollama · llama3.1"]
    @State private var selectedProviderOption: String = "claude · tài khoản"
    @State private var isRefreshing = false

    var body: some View {
        HStack(spacing: 12) {
            logo
            VStack(alignment: .leading, spacing: 1) {
                Text("Aurora Feed")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundColor(NewsAuroraStyle.ink)
                Text("AI tổng hợp & dịch · tiếng Việt")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(NewsAuroraStyle.muted)
            }
            kbdHint
            Spacer(minLength: 12)
            roleSegmented
            providerPill
            refreshButton
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(NewsAuroraStyle.glass)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(NewsAuroraStyle.line, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 24, x: 0, y: 10)
        .task { await loadConfig() }
    }

    // MARK: - Brand

    private var logo: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: [NewsAuroraStyle.violet, NewsAuroraStyle.cyan],
                                  startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 34, height: 34)
            .overlay(Text("✶").font(.system(size: 15, weight: .black)).foregroundColor(.white))
    }

    private var kbdHint: some View {
        Text("⌥X")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(NewsAuroraStyle.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.7))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(NewsAuroraStyle.line, lineWidth: 1))
            )
    }

    // MARK: - Role segmented (Master/Client)

    private var roleSegmented: some View {
        HStack(spacing: 3) {
            roleButton(title: "Master", value: "master")
            roleButton(title: "Client", value: "client")
        }
        .padding(3)
        .background(
            Capsule().fill(Color.white.opacity(0.5))
                .overlay(Capsule().strokeBorder(NewsAuroraStyle.line, lineWidth: 1))
        )
    }

    private func roleButton(title: String, value: String) -> some View {
        let isOn = settings.newsRole == value
        return Button {
            settings.newsRole = value
        } label: {
            Text(title)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundColor(isOn ? .white : NewsAuroraStyle.muted)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isOn ?
                        AnyShapeStyle(LinearGradient(colors: [NewsAuroraStyle.violet, Color(red: 0xa7 / 255, green: 0x8b / 255, blue: 0xfa / 255)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color.clear))
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - Provider pill

    private var providerPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isRefreshing ? Color.orange : NewsAuroraStyle.green)
                .frame(width: 9, height: 9)
            Picker("", selection: $selectedProviderOption) {
                ForEach(providerOptions, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 130)
            .onChange(of: selectedProviderOption) { _, newValue in
                Task { await persistProvider(newValue) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(Color.white.opacity(0.6))
                .overlay(Capsule().strokeBorder(NewsAuroraStyle.line, lineWidth: 1))
        )
    }

    // MARK: - Refresh

    private var refreshButton: some View {
        Button {
            Task {
                isRefreshing = true
                await store.refresh(force: true)
                isRefreshing = false
            }
        } label: {
            Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.clockwise")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(NewsAuroraStyle.ink)
                .padding(8)
                .background(Circle().fill(Color.white.opacity(0.6)))
                .overlay(Circle().strokeBorder(NewsAuroraStyle.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .disabled(isRefreshing)
    }

    // MARK: - Config round-trip (best-effort; backend lands in Phase 2/3)

    private func loadConfig() async {
        // Build the option list from the machine's ACTUAL installed Ollama
        // models plus Claude (when the account is reachable).
        var options: [String] = []
        var firstOllamaModel: String?
        if let providers = try? await client.newsProviders() {
            firstOllamaModel = providers.ollamaModels.first
            for model in providers.ollamaModels {
                options.append(optionLabel(provider: "ollama", model: model))
            }
            if providers.claudeAvailable {
                options.append(optionLabel(provider: "claude", model: ""))
            }
        }

        // Reflect the persisted choice. Empty ollamaModel means "auto-pick the
        // first installed model" — resolve it for display so the pill matches
        // a real option instead of showing a placeholder.
        if let config = try? await client.newsConfigGet() {
            let model = (config.provider == "ollama" && config.ollamaModel.isEmpty)
                ? (firstOllamaModel ?? "")
                : config.ollamaModel
            let current = optionLabel(provider: config.provider, model: model)
            if !options.contains(current) { options.insert(current, at: 0) }
            selectedProviderOption = current
        } else if let feed = Optional(store.feed), !feed.provider.isEmpty {
            // Backend config unreadable — reflect whatever the cached feed used.
            let label = optionLabel(provider: feed.provider, model: feed.model)
            if !options.contains(label) { options.insert(label, at: 0) }
            selectedProviderOption = label
        }

        if !options.isEmpty {
            providerOptions = options
            if !options.contains(selectedProviderOption) {
                selectedProviderOption = options.first ?? selectedProviderOption
            }
        }
    }

    private func optionLabel(provider: String, model: String) -> String {
        switch provider {
        case "claude": return "claude · \(model.isEmpty ? "tài khoản" : model)"
        default:       return "ollama · \(model.isEmpty ? "…" : model)"
        }
    }

    private func persistProvider(_ option: String) async {
        let parts = option.components(separatedBy: " · ")
        guard let provider = parts.first else { return }
        let model = parts.count > 1 ? parts[1] : ""
        // Read-modify-write the REAL config so feeds/GitHub queries are
        // preserved. If the current config can't be read, skip the write
        // rather than synthesising an empty one that would wipe the seeded
        // defaults — the picker's local selection still reflects the choice.
        guard var config = try? await client.newsConfigGet() else { return }
        config.provider = provider
        if provider == "ollama" { config.ollamaModel = model }
        _ = try? await client.newsConfigSet(config)
    }
}
