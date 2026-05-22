import SwiftUI

/// Editor for the user's news feed list — add / edit / remove rows.
/// Persists to `AppSettings.briefingNewsFeedsJSON`.
struct NewsFeedsEditor: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var feeds: [NewsFeedConfig] = []
    @State private var newLabel: String = ""
    @State private var newURL: String = ""
    @State private var newMode: NewsFeedConfig.Mode = .rss

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(feeds) { feed in
                row(for: feed)
            }
            if feeds.isEmpty {
                Text("No feeds yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 4)

            HStack(spacing: 8) {
                TextField("Name (e.g. Hacker News)", text: $newLabel)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                TextField("https://…", text: $newURL)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $newMode) {
                    ForEach(NewsFeedConfig.Mode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
                Button("Add") { addFeed() }
                    .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty
                              || newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task { feeds = .decode(from: settings.briefingNewsFeedsJSON) }
    }

    @ViewBuilder private func row(for feed: NewsFeedConfig) -> some View {
        HStack {
            Toggle("", isOn: bindingForEnabled(feed.id))
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(feed.label).font(.body.weight(.medium))
                Text(feed.url)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(feed.mode.label)
                .font(.caption2).foregroundStyle(.secondary)
            Button {
                remove(feed.id)
            } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func bindingForEnabled(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { feeds.first(where: { $0.id == id })?.enabled ?? false },
            set: { newVal in
                guard let idx = feeds.firstIndex(where: { $0.id == id }) else { return }
                feeds[idx].enabled = newVal
                persist()
            }
        )
    }

    private func addFeed() {
        let label = newLabel.trimmingCharacters(in: .whitespaces)
        let url = newURL.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, !url.isEmpty else { return }
        feeds.append(NewsFeedConfig(url: url, label: label, mode: newMode))
        persist()
        newLabel = ""; newURL = ""; newMode = .rss
    }

    private func remove(_ id: UUID) {
        feeds.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        settings.briefingNewsFeedsJSON = feeds.encodeToJSON()
    }
}
