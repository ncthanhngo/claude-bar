import SwiftUI

/// Daily → Tools → "Theo dõi CI". One-click installer for the machine-wide
/// CI tooling: a `ci-watch` CLI + a `glpush` zsh function that, after every
/// push, watches the GitLab/GitHub pipeline in the background and notifies on
/// finish. GitLab auth is bootstrapped from the MCP GitLab token the app
/// already stores; if none exists yet, an inline form lets the user fill it
/// right here in Daily → Tools.
struct CIToolsBody: View {
    @ObservedObject var store: CIToolsStore
    let palette: BriefingPalette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statusCard
                if !store.hasToken { tokenForm }
                installSection
                if !store.installLog.isEmpty { logCard }
                if let err = store.lastError { errorRow(err) }
            }
            .padding(.trailing, 4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task { await store.load() }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Theo dõi CI")
                .font(.system(size: 21, weight: .semibold, design: .serif))
                .foregroundColor(palette.ink)
            Text("Cài `ci-watch` + `glpush` vào máy. Sau khi push, pipeline GitLab/GitHub được theo dõi nền và báo khi xong — áp dụng mọi repo trên máy này.")
                .font(.system(size: 11.5))
                .foregroundColor(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: status

    private var statusCard: some View {
        let s = store.status
        return VStack(alignment: .leading, spacing: 10) {
            Text("Trạng thái").font(.system(size: 12, weight: .semibold)).foregroundColor(palette.ink2)
            FlowChips {
                chip("glab", s?.glab ?? false)
                chip("gh", s?.gh ?? false)
                chip("ci-watch", s?.ciWatch ?? false)
                chip("glpush", s?.glpush ?? false)
                chip("GitHub auth", s?.ghAuthed ?? false)
            }
            if let hosts = s?.hostsAuthed, !hosts.isEmpty {
                Text("GitLab đã auth: \(hosts.joined(separator: ", "))")
                    .font(.system(size: 11)).foregroundColor(palette.sage)
            } else {
                Text("GitLab đã auth: chưa có")
                    .font(.system(size: 11)).foregroundColor(palette.ink3)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.paper2))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
    }

    private func chip(_ label: String, _ ok: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(ok ? palette.sage : palette.ink3)
            Text(label).font(.system(size: 11.5, weight: .medium)).foregroundColor(palette.ink2)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(ok ? palette.sage.opacity(0.12) : palette.blush.opacity(0.5)))
    }

    // MARK: inline GitLab token form (when no MCP token yet)

    private var tokenForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chưa có token GitLab MCP — điền để dùng tính năng")
                .font(.system(size: 12, weight: .semibold)).foregroundColor(palette.ink)
            field("Tên hiển thị", text: $store.formName, placeholder: "vd: EVSELab")
            field("Base URL", text: $store.formBaseURL, placeholder: "https://gitlab.example.com/api/v4")
            secureField("Personal Access Token", text: $store.formPAT, placeholder: "glpat-…")
            HStack {
                Spacer()
                Button { Task { await store.saveTokenForm() } } label: {
                    Label("Lưu token", systemImage: "key.fill").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canSubmitForm || store.busy)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.blush.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line2, lineWidth: 1))
    }

    // MARK: install

    private var installSection: some View {
        HStack(spacing: 12) {
            Button { Task { await store.install() } } label: {
                HStack(spacing: 6) {
                    if store.busy { ProgressView().controlSize(.small) }
                    Image(systemName: "square.and.arrow.down.on.square")
                    Text(store.status?.installed == true ? "Cài lại / cập nhật" : "Cài đặt vào máy")
                        .fontWeight(.semibold)
                }
                .font(.system(size: 13))
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.busy)

            Button { Task { await store.load() } } label: {
                Label("Làm mới", systemImage: "arrow.clockwise").font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .disabled(store.busy)

            Spacer()
            if store.status?.installed == true {
                Label("Đã sẵn sàng", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(palette.sage)
            }
        }
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nhật ký cài đặt").font(.system(size: 11, weight: .semibold)).foregroundColor(palette.ink3)
            ForEach(Array(store.installLog.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.paper2))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
    }

    private func errorRow(_ msg: String) -> some View {
        Label(msg, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11.5)).foregroundColor(palette.coral)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: field helpers

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundColor(palette.ink3)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }

    private func secureField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundColor(palette.ink3)
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }
}

/// Minimal wrap layout for status chips (avoids a hard dependency on iOS 16+
/// `Layout`; chips are few so a simple HStack-with-wrap via `WrappingHStack`
/// isn't warranted — a single flexible row is fine at this width).
private struct FlowChips<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 8) { content; Spacer(minLength: 0) }
    }
}
