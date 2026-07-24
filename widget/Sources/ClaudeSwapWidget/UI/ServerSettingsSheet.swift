import SwiftUI
import AppKit

/// Server management sheet opened from the Server tab's gear. Add / edit /
/// delete tracked SSH hosts with real credentials: display name (rename),
/// user@host:port, and a private key (key-based auth). The identity `name`
/// stays fixed — renaming edits the display label only.
struct ServerSettingsSheet: View {
    @EnvironmentObject private var monitor: ServerMonitorStore
    @ObservedObject private var settings = AppSettings.shared
    /// Closes the hosting floating window (MenuBarExtra can't keep a `.sheet`
    /// alive — it collapses the popover on focus loss, so this lives in its
    /// own NSWindow via ServerSettingsWindowController).
    let onClose: () -> Void

    private enum Mode: Equatable {
        case list
        case add
        case edit(String)  // host identity name
    }
    @State private var mode: Mode = .list

    // Shared form state.
    @State private var fName = ""       // identity (ID), add-only
    @State private var fDisplay = ""
    @State private var fHost = ""
    @State private var fUser = ""
    @State private var fPort = ""
    @State private var fIdentity = ""
    @State private var fDiskPath = ""
    @State private var fPassword = ""
    @State private var fHadPassword = false   // host already has a stored password
    @State private var fClearPassword = false // user asked to remove it
    @State private var fJump = ""
    @State private var fCheckPort = ""
    @State private var editingName: String?

    var body: some View {
        Group {
            if mode == .list { listView } else { formView }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - list

    private var listView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Quản lý server").font(.system(size: 16, weight: .semibold))
                Spacer()
                Menu {
                    Button { exportBundle() } label: {
                        Label("Xuất ra file…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(monitor.hosts.isEmpty)
                    Button { importBundle(replace: false) } label: {
                        Label("Nhập từ file (gộp)…", systemImage: "square.and.arrow.down")
                    }
                    Button(role: .destructive) { importBundle(replace: true) } label: {
                        Label("Nhập & thay thế toàn bộ…", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(monitor.hosts.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 15))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Xuất / nhập danh sách server (.cbssh mã hoá)")
                Button { resetForm(); mode = .add } label: {
                    Label("Thêm", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            Divider()
            configStrip
            Divider()

            if monitor.hosts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(monitor.hosts) { host in row(host) }
                    }
                    .padding(16)
                }
            }

            Divider()
            HStack {
                if let err = monitor.lastError {
                    Text(err).font(.system(size: 11)).foregroundColor(.red).lineLimit(2)
                }
                Spacer()
                Button("Xong") { onClose() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }

    private var configStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Nhịp kiểm tra").font(.system(size: 11)).foregroundColor(.secondary)
                Stepper("\(settings.serverPollIntervalMinutes) phút",
                        value: $settings.serverPollIntervalMinutes, in: 1...60)
                    .font(.system(size: 11)).fixedSize()
            }
            HStack(spacing: 12) {
                Text("Ngưỡng disk").font(.system(size: 11)).foregroundColor(.secondary)
                Stepper("cảnh báo \(settings.serverDiskWarnPct)%",
                        value: $settings.serverDiskWarnPct, in: 50...99).font(.system(size: 11)).fixedSize()
                Stepper("nguy hiểm \(settings.serverDiskCritPct)%",
                        value: $settings.serverDiskCritPct, in: 50...100).font(.system(size: 11)).fixedSize()
            }
            Toggle(isOn: $settings.serverDiskAlertsEnabled) {
                Text("Thông báo khi disk vượt ngưỡng nguy hiểm").font(.system(size: 11))
            }
            .toggleStyle(.switch).controlSize(.mini)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func row(_ h: CswClient.SSHHostDTO) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack").foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(h.displayName).font(.system(size: 13, weight: .semibold))
                Text(h.target.isEmpty ? h.name : h.target)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            if h.isMonitored {
                Text("Theo dõi").font(.system(size: 10, weight: .medium)).foregroundColor(.green)
            }
            Button("Sửa") { loadForm(h); editingName = h.name; mode = .edit(h.name) }
                .buttonStyle(.bordered)
            Button { Task { await monitor.removeHost(name: h.name) } } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain).foregroundColor(.secondary)
            .help("Xoá server")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack").font(.system(size: 28)).foregroundColor(.secondary)
            Text("Chưa có server nào").font(.system(size: 13, weight: .medium))
            Text("Bấm “Thêm” để nhập tài khoản server thật + private key.")
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - form (add / edit)

    private var formView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(mode == .add ? "Thêm server" : "Sửa server")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if mode == .add {
                        field("Định danh (ID)", "vd: prod-1", $fName)
                        Text("ID cố định dùng nội bộ (backup/assistant tham chiếu). Tên hiển thị đổi ở ô dưới.")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    field("Tên hiển thị", "vd: Web Production", $fDisplay)
                    field("Host / IP", "vd: 10.0.0.5", $fHost)
                    HStack(alignment: .bottom, spacing: 12) {
                        field("User (tài khoản server)", "vd: root", $fUser)
                        field("Port", "22", $fPort).frame(width: 90)
                    }
                    passwordField
                    keyField
                    field("ProxyJump / bastion (tuỳ chọn)", "vd: user@bastion", $fJump)
                    HStack(alignment: .bottom, spacing: 12) {
                        field("Đường dẫn disk theo dõi", "/ hoặc /,/data", $fDiskPath)
                        field("Check port", "vd: 443", $fCheckPort).frame(width: 110)
                    }
                }
                .padding(16)
            }

            Divider()
            HStack {
                Button("Huỷ") { mode = .list }
                Spacer()
                Button("Lưu") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(saveDisabled)
            }
            .padding(16)
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mật khẩu (tuỳ chọn)").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            HStack(spacing: 8) {
                SecureField(fHadPassword ? "(đã lưu — nhập để đổi)" : "Mật khẩu server", text: $fPassword)
                    .textFieldStyle(.roundedBorder)
                    .disabled(fClearPassword)
                if fHadPassword && !fClearPassword {
                    Button("Xoá") { fClearPassword = true; fPassword = "" }
                        .help("Xoá mật khẩu đã lưu")
                }
                if fClearPassword {
                    Text("sẽ xoá").font(.system(size: 10)).foregroundColor(.orange)
                    Button { fClearPassword = false } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.plain).foregroundColor(.secondary).help("Hoàn tác")
                }
            }
            Text("Có mật khẩu sẽ thử trước; sai hoặc không có thì tự fallback private key. Lưu trong Keychain.")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Private key").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            HStack(spacing: 8) {
                TextField("~/.ssh/id_ed25519", text: $fIdentity).textFieldStyle(.roundedBorder)
                Button("Chọn…") { pickKey() }
                if !fIdentity.isEmpty {
                    Button { fIdentity = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                }
            }
            Text("Đăng nhập bằng khoá riêng. Để trống nếu dùng cấu hình ~/.ssh mặc định.")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private var saveDisabled: Bool {
        let host = fHost.trimmed
        if mode == .add { return fName.trimmed.isEmpty || host.isEmpty }
        return host.isEmpty
    }

    // MARK: - actions

    private func pickKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.title = "Chọn private key"
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if FileManager.default.fileExists(atPath: ssh.path) { panel.directoryURL = ssh }
        if panel.runModal() == .OK, let url = panel.url { fIdentity = url.path }
    }

    /// Export the tracked-host list to an encrypted `.cbssh` file. Asks for a
    /// destination path, then a passphrase to protect it.
    private func exportBundle() {
        let panel = NSSavePanel()
        panel.title = "Xuất danh sách server"
        panel.nameFieldStringValue = "servers.cbssh"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let pass = promptPassphrase(
            title: "Đặt mật khẩu bảo vệ file",
            message: "File .cbssh được mã hoá bằng mật khẩu này. Máy nhập cần đúng mật khẩu để mở."
        ) else { return }
        Task { await monitor.exportBundle(toPath: url.path, passphrase: pass) }
    }

    /// Import hosts from a `.cbssh` file. Asks for the file, then its passphrase.
    /// `replace` false merges into the existing list (non-destructive); true
    /// wipes the current list first and asks for confirmation before doing so.
    private func importBundle(replace: Bool) {
        let panel = NSOpenPanel()
        panel.title = "Chọn file .cbssh"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if replace && !confirmReplace() { return }
        guard let pass = promptPassphrase(
            title: "Nhập mật khẩu của file",
            message: "Nhập mật khẩu đã dùng khi xuất file này."
        ) else { return }
        Task { await monitor.importBundle(fromPath: url.path, passphrase: pass, merge: !replace) }
    }

    /// Destructive-action confirm before wiping the tracked-host list on a
    /// replace import.
    private func confirmReplace() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Thay thế toàn bộ danh sách server?"
        alert.informativeText = "Xoá \(monitor.hosts.count) server hiện có rồi nhập từ file. Không thể hoàn tác."
        alert.addButton(withTitle: "Thay thế")
        alert.addButton(withTitle: "Huỷ")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Modal passphrase prompt (AppKit — the panels above are already modal, so
    /// a SwiftUI sheet would fight the host NSWindow). Returns nil on cancel or
    /// empty input.
    private func promptPassphrase(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Huỷ")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Mật khẩu"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let pass = field.stringValue
        return pass.isEmpty ? nil : pass
    }

    private func save() {
        let port = Int(fPort.trimmed) ?? 0
        let display = fDisplay.trimmed
        let host = fHost.trimmed
        let user = fUser.trimmed
        let identity = fIdentity.trimmed
        let disk = fDiskPath.trimmed
        let identityName: String
        switch mode {
        case .add: identityName = fName.trimmed
        case .edit(let name): identityName = name
        case .list: return
        }
        // Password isn't trimmed — it may legitimately contain spaces.
        let password = fPassword
        let clearPassword = fClearPassword
        let jump = fJump.trimmed
        let checkPort = Int(fCheckPort.trimmed) ?? 0
        Task {
            switch mode {
            case .add:
                await monitor.addHost(name: identityName, display: display, host: host,
                                      user: user, port: port, identity: identity, diskPath: disk,
                                      jump: jump, checkPort: checkPort)
            case .edit(let name):
                await monitor.updateHost(name: name, displayName: display, host: host,
                                         user: user, port: port, identity: identity, diskPath: disk,
                                         jump: jump, checkPort: checkPort)
            case .list:
                break
            }
            // Password applied after the host exists: clear, set, or leave as-is.
            if clearPassword {
                await monitor.setPassword(host: identityName, password: "")
            } else if !password.isEmpty {
                await monitor.setPassword(host: identityName, password: password)
            }
            mode = .list
        }
    }

    private func resetForm() {
        fName = ""; fDisplay = ""; fHost = ""; fUser = ""; fPort = ""; fIdentity = ""; fDiskPath = ""
        fPassword = ""; fHadPassword = false; fClearPassword = false
        fJump = ""; fCheckPort = ""
        editingName = nil
    }

    private func loadForm(_ h: CswClient.SSHHostDTO) {
        fName = h.name
        fDisplay = h.label ?? ""
        fHost = h.hostNameOr
        fUser = h.userOr
        fPort = h.portOr > 0 ? String(h.portOr) : ""
        fIdentity = h.identityFile ?? ""
        fDiskPath = h.diskPath ?? ""
        fPassword = ""; fClearPassword = false
        fHadPassword = h.hasPassword
        fJump = h.jumpHost ?? ""
        fCheckPort = (h.checkPort ?? 0) > 0 ? String(h.checkPort!) : ""
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
