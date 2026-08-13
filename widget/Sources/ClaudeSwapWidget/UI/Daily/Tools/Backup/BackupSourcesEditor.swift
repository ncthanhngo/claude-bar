import SwiftUI

/// Editor for the profile's backup sources. Each source is a command dump, a
/// set of paths, or docker volumes — keeping the feature DB-agnostic.
struct BackupSourcesEditor: View {
    @Binding var profile: BackupProfile
    let palette: BriefingPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Nguồn sao lưu", systemImage: "shippingbox")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(palette.ink)
                Spacer()
                Menu {
                    Button("Lệnh dump (pg_dump…)") { add(.command) }
                    Button("Thư mục / file") { add(.path) }
                    Button("Docker volume") { add(.volume) }
                } label: {
                    Label("Thêm", systemImage: "plus").font(.system(size: 11, weight: .medium))
                }.menuStyle(.borderlessButton).frame(width: 70)
            }

            if profile.sources.isEmpty {
                Text("Chưa có nguồn nào. Thêm ít nhất một nguồn để sao lưu.")
                    .font(.system(size: 11)).foregroundColor(palette.ink3)
            }

            ForEach($profile.sources) { $src in
                sourceRow($src)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.raisedSurface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
    }

    private func add(_ kind: BackupSourceKind) {
        profile.sources.append(BackupSource(kind: kind, name: defaultName(kind)))
    }

    private func defaultName(_ kind: BackupSourceKind) -> String {
        switch kind {
        case .command: return "db"
        case .path: return "config"
        case .volume: return "vols"
        }
    }

    @ViewBuilder private func sourceRow(_ src: Binding<BackupSource>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: src.kind) {
                    ForEach(BackupSourceKind.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().pickerStyle(.menu).frame(width: 130)
                TextField("tên (a-z, số, _ -)", text: src.name)
                    .textFieldStyle(.roundedBorder)
                Button { remove(src.wrappedValue.id) } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundColor(palette.coral)
            }

            switch src.wrappedValue.kind {
            case .command:
                hint("Lệnh dump — stdout sẽ được lưu thành <tên>.dump")
                TextField("docker exec pg pg_dump -U app db", text: src.dumpCmd.orEmpty)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                hint("Lệnh khôi phục — đọc <tên>.dump từ stdin")
                TextField("docker exec -i pg psql -U app db", text: src.restoreCmd.orEmpty)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
            case .path:
                hint("Đường dẫn tuyệt đối trên server (mỗi dòng một path)")
                MultilineList(values: src.paths, placeholder: "/etc/app", palette: palette)
            case .volume:
                hint("Tên docker volume (mỗi dòng một volume)")
                MultilineList(values: src.volumes, placeholder: "app_pgdata", palette: palette)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(palette.paper2))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.line, lineWidth: 1))
    }

    private func remove(_ id: UUID) {
        profile.sources.removeAll { $0.id == id }
    }

    private func hint(_ t: String) -> some View {
        Text(t).font(.system(size: 10)).foregroundColor(palette.ink3)
    }
}

/// One-text-field-per-line editor backed by a [String]. Empty lines are dropped.
private struct MultilineList: View {
    @Binding var values: [String]
    let placeholder: String
    let palette: BriefingPalette

    var body: some View {
        let text = Binding(
            get: { values.joined(separator: "\n") },
            set: { values = $0.split(separator: "\n", omittingEmptySubsequences: true).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        )
        TextEditor(text: text)
            .font(.system(size: 11, design: .monospaced))
            .frame(minHeight: 44, maxHeight: 88)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(palette.raisedSurface))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.line, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if values.isEmpty {
                    Text(placeholder).font(.system(size: 11, design: .monospaced))
                        .foregroundColor(palette.ink3).padding(.horizontal, 9).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
    }
}

private extension Binding where Value == String? {
    var orEmpty: Binding<String> {
        Binding<String>(get: { wrappedValue ?? "" }, set: { wrappedValue = $0.isEmpty ? nil : $0 })
    }
}
