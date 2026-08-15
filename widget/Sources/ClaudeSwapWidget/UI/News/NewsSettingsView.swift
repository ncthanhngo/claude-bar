import SwiftUI

/// Settings → News tab. Two kinds of state, deliberately kept apart (see
/// contract.md "Config ownership split"):
///   • Go-owned aggregation config (provider, model, Claude fallback, feed
///     list, GitHub queries) — round-tripped through `csw news config get|set`.
///     Reads/writes here are wrapped in `try?`/explicit error text because
///     the backend command doesn't exist until Phase 2; this tab must degrade
///     to "showing an error, not crashing" until then.
///   • Machine-local behaviour (role, relay host id/dir, refresh interval) —
///     plain `@AppStorage` on `AppSettings`, no round-trip needed.
struct NewsSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    private let client = CswClient()

    @State private var config: NewsConfigDTO?
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var newFeedURL = ""
    @State private var newFeedLabel = ""
    /// True only after `newsConfigGet()` actually returned a config. Guards
    /// `save()` so a config synthesised in the error fallback (empty feeds /
    /// GitHub queries) can never be written back over the Go-seeded defaults.
    @State private var configFromBackend = false
    /// Local draft for the Ollama model field so typing doesn't fire a
    /// `csw news config set` subprocess per keystroke — persisted on submit.
    @State private var ollamaModelDraft = ""

    var body: some View {
        ScrollView {
            SettingsPage {
                SettingsGroup(
                    "Vai trò máy này",
                    subtitle: "Master tự tổng hợp tin bằng AI rồi đẩy lên relay. Client chỉ tải news.json đã tổng hợp sẵn từ relay về xem."
                ) {
                    Picker("Vai trò", selection: $settings.newsRole) {
                        Text("Master").tag("master")
                        Text("Client").tag("client")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }

                SettingsGroup(
                    "Relay (server trung gian qua SSH)",
                    subtitle: settings.newsRole == "master"
                        ? "Sau mỗi lần tổng hợp, Master đẩy news.json lên host này để các máy Client tải về. Bỏ trống nếu chỉ dùng cục bộ."
                        : "Client tải news.json từ host này. Chọn host trong Netbird → SSH trước."
                ) {
                    relayFields
                }

                SettingsGroup(
                    "Làm mới tự động",
                    subtitle: "Ngoài lần mở cửa sổ đầu tiên và nút làm mới thủ công, News sẽ tự tổng hợp lại theo chu kỳ này."
                ) {
                    Stepper(value: $settings.newsRefreshIntervalHours, in: 1...24) {
                        Text("Mỗi \(settings.newsRefreshIntervalHours) giờ")
                    }
                }

                SettingsGroup(
                    "Nhà cung cấp AI",
                    subtitle: "Ollama (mặc định, chạy cục bộ tại localhost:11434) hoặc Claude (tài khoản đang hoạt động) làm nguồn tóm tắt & dịch."
                ) {
                    providerSection
                }

                SettingsGroup(
                    "Nguồn tin (RSS / Atom)",
                    subtitle: "Danh sách nguồn Master sẽ tổng hợp. Yêu cầu backend Phase 2 — hiện tại lưu vào cấu hình Go qua `csw news config set`."
                ) {
                    feedsSection
                }
            }
        }
        .task { await loadConfig() }
    }

    // MARK: - Relay (role = client)

    private var relayFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Relay SSH host ID", text: $settings.newsRelayHostID)
                .textFieldStyle(.roundedBorder)
            TextField("Relay remote dir (vd: ~/claude-bar-news)", text: $settings.newsRelayRemoteDir)
                .textFieldStyle(.roundedBorder)
            Text("Host phải được thêm trong Netbird → SSH trước. remote dir sẽ chứa news.json + manifest.json.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Provider (Go config)

    @ViewBuilder
    private var providerSection: some View {
        if let error = loadError {
            errorRow(error)
        }
        if let config {
            Picker("Provider", selection: providerBinding(for: config)) {
                Text("Ollama").tag("ollama")
                Text("Claude").tag("claude")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)

            if config.provider == "ollama" {
                TextField("Model (vd: qwen2.5)", text: $ollamaModelDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit { commitOllamaModel(for: config) }
                Text("Để trống = tự chọn model Ollama đầu tiên đang cài. Nhấn Enter để lưu.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Picker("Dự phòng khi Ollama lỗi", selection: fallbackBinding(for: config)) {
                Text("Không dùng").tag(false)
                Text("Claude").tag(true)
            }
            .pickerStyle(.radioGroup)
            Text("Mặc định không dự phòng: Ollama không phản hồi (không chạy / model chưa tải) thì lượt tổng hợp đó báo lỗi. Chọn Claude để tự chuyển sang tài khoản Claude đang hoạt động cho lượt đó.")
                .font(.caption2)
                .foregroundColor(.secondary)

            if isSaving {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Đang lưu…").font(.caption).foregroundColor(.secondary)
                }
            }
        } else if loadError == nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Đang tải cấu hình…").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func providerBinding(for config: NewsConfigDTO) -> Binding<String> {
        Binding(
            get: { config.provider },
            set: { newValue in
                var updated = config
                updated.provider = newValue
                self.config = updated
                Task { await save(updated) }
            }
        )
    }

    /// Persists the Ollama model draft (on Enter / submit) rather than on every
    /// keystroke.
    private func commitOllamaModel(for config: NewsConfigDTO) {
        let trimmed = ollamaModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != config.ollamaModel else { return }
        var updated = config
        updated.ollamaModel = trimmed
        self.config = updated
        Task { await save(updated) }
    }

    private func fallbackBinding(for config: NewsConfigDTO) -> Binding<Bool> {
        Binding(
            get: { config.claudeFallbackEnabled },
            set: { newValue in
                var updated = config
                updated.claudeFallbackEnabled = newValue
                self.config = updated
                Task { await save(updated) }
            }
        )
    }

    // MARK: - Feeds (Go config)

    @ViewBuilder
    private var feedsSection: some View {
        if let config {
            if config.feeds.isEmpty {
                Text("Chưa có nguồn nào.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(config.feeds) { feed in
                    feedRow(feed, config: config)
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Tên nguồn (vd: Hacker News)", text: $newFeedLabel)
                    .textFieldStyle(.roundedBorder)
                TextField("URL feed", text: $newFeedURL)
                    .textFieldStyle(.roundedBorder)
                Button("Thêm") { addFeed(to: config) }
                    .disabled(newFeedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func feedRow(_ feed: NewsConfigFeedDTO, config: NewsConfigDTO) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { feed.enabled },
                set: { newValue in setFeedEnabled(feedID: feed.id, enabled: newValue, config: config) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(feed.label).font(.system(size: 13, weight: .medium))
                    Text(feed.url).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                removeFeed(feedID: feed.id, config: config)
            } label: {
                Image(systemName: "trash").foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
    }

    private func addFeed(to config: NewsConfigDTO) {
        let url = newFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        let label = newFeedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = config
        updated.feeds.append(NewsConfigFeedDTO(
            id: UUID().uuidString, url: url, label: label.isEmpty ? url : label, mode: "rss", enabled: true
        ))
        self.config = updated
        newFeedURL = ""
        newFeedLabel = ""
        Task { await save(updated) }
    }

    private func removeFeed(feedID: String, config: NewsConfigDTO) {
        var updated = config
        updated.feeds.removeAll { $0.id == feedID }
        self.config = updated
        Task { await save(updated) }
    }

    private func setFeedEnabled(feedID: String, enabled: Bool, config: NewsConfigDTO) {
        var updated = config
        if let idx = updated.feeds.firstIndex(where: { $0.id == feedID }) {
            updated.feeds[idx].enabled = enabled
        }
        self.config = updated
        Task { await save(updated) }
    }

    // MARK: - Backend round-trip

    private func loadConfig() async {
        do {
            let loaded = try await client.newsConfigGet()
            config = loaded
            ollamaModelDraft = loaded.ollamaModel
            configFromBackend = true
            loadError = nil
        } catch {
            // Backend unreadable — show a read-only placeholder so the tab
            // doesn't spin forever, but DON'T mark it backend-sourced: `save()`
            // refuses to persist it, so its empty feeds/queries can never
            // overwrite the Go-seeded defaults.
            loadError = "Chưa đọc được cấu hình từ backend (\(error.localizedDescription)). Mở lại tab khi backend sẵn sàng để chỉnh."
            config = NewsConfigDTO(
                provider: "ollama", ollamaModel: "", claudeFallbackEnabled: false,
                feeds: [], githubQueries: []
            )
            ollamaModelDraft = ""
            configFromBackend = false
        }
    }

    private func save(_ config: NewsConfigDTO) async {
        // Never persist a config we didn't actually load from the backend —
        // that would write empty feeds/queries over the seeded defaults.
        guard configFromBackend else {
            loadError = "Chưa đọc được cấu hình từ backend nên tạm thời không thể lưu thay đổi."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await client.newsConfigSet(config)
            loadError = nil
        } catch {
            loadError = "Không lưu được cấu hình: \(error.localizedDescription)"
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
