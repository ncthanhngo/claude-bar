import SwiftUI

/// Generates an enrollment setup key and shows, per target (server VPS Ubuntu or
/// dev Ubuntu / macOS / Windows), two copy-paste commands: ① a full fresh setup
/// that installs NetBird, and ② a fast fix (down + up) for a machine that is
/// already installed but mis-enrolled. The key is shown once, here; never
/// persisted in plaintext. Mirrors scripts/netbird-enroll/*.
struct NetbirdSetupKeyButton: View {
    @ObservedObject var coord: NetbirdCoordinator
    let palette: BriefingPalette
    @State private var showing = false
    @State private var showingPeople = false
    @State private var key: NBSetupKey?
    @State private var recipient: NetbirdPerson?
    @State private var target: EnrollTarget = .serverUbuntu

    var body: some View {
        Menu {
            if !coord.people.isEmpty {
                Section("Cấp key 1 lần cho") {
                    ForEach(coord.people) { p in
                        Button { issue(for: p) } label: {
                            Text(p.team.isEmpty ? p.name : "\(p.name) · \(p.team)")
                        }
                    }
                }
            }
            Button { issue(for: nil) } label: {
                Label("Ẩn danh / không gắn người", systemImage: "person.crop.circle.badge.questionmark")
            }
            Divider()
            Button { showingPeople = true } label: {
                Label("Quản lý danh bạ…", systemImage: "person.2")
            }
        } label: {
            Label("Thêm máy", systemImage: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(palette.moss))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(coord.busy)
        .popover(isPresented: $showing) {
            if let k = key { keySheet(k) }
        }
        .sheet(isPresented: $showingPeople) {
            NetbirdPeopleView(coord: coord, palette: palette)
        }
    }

    /// Generate a single-use key for `person` (or anonymous), naming it after
    /// them so the key is traceable, then open the command sheet.
    private func issue(for person: NetbirdPerson?) {
        recipient = person
        Task {
            let name = person.map { "enroll: \($0.name)" } ?? "dev-enroll"
            key = await coord.createSetupKey(name: name)
            showing = key != nil
        }
    }

    /// Open the default mail client with the enrollment command pre-filled to
    /// the recipient. Note: a setup key sent over email is a secret on an
    /// unencrypted channel — the single-use + 24h-expiry key keeps the exposure
    /// window tight, which is why this flow only issues one-off keys.
    private func composeEmail(_ k: NBSetupKey, to person: NetbirdPerson) {
        let subject = "Hướng dẫn vào mạng nội bộ (key dùng 1 lần, hết hạn 24h)"
        let body = """
        Chào \(person.name),

        Chạy lệnh dưới để cài và kết nối máy vào mạng nội bộ. Key chỉ dùng được 1 lần và hết hạn sau 24 giờ — chạy sớm giúp mình.

        \(freshCommand(k.key, target))

        Chạy xong báo lại để mình duyệt và cấp quyền. Cảm ơn!
        """
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = person.email
        comps.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    /// Enrollment targets. `serverUbuntu` turns on NetBird's built-in SSH so
    /// granted devs reach it with `netbird ssh` (no authorized_keys). Dev
    /// targets land the machine in the dev-pending group for approval.
    private enum EnrollTarget: String, CaseIterable, Identifiable {
        case serverUbuntu, devUbuntu, devMacOS, devWindows
        var id: String { rawValue }
        var label: String {
            switch self {
            case .serverUbuntu: return "Server · VPS Ubuntu"
            case .devUbuntu:    return "Dev · Ubuntu"
            case .devMacOS:     return "Dev · macOS"
            case .devWindows:   return "Dev · Windows"
            }
        }
        var isServer: Bool { self == .serverUbuntu }
        var isWindows: Bool { self == .devWindows }
    }

    // MARK: command building

    /// Management server URL for `--management-url`: the configured API base with
    /// the trailing `/api` stripped. Self-hosted clients MUST point here — a
    /// plain `netbird up` defaults to NetBird Cloud (api.netbird.io) and rejects
    /// a self-host setup key, which is the usual "enroll failed" cause.
    private var managementURL: String {
        var u = coord.baseURL.trimmingCharacters(in: .whitespaces)
        if u.hasSuffix("/api") { u = String(u.dropLast(4)) }
        while u.hasSuffix("/") { u = String(u.dropLast()) }
        return u.isEmpty ? "https://netbird.evselab.com" : u
    }

    /// The `netbird up …` line shared by both the fresh-install and quick-fix
    /// commands — carries the setup key, the management URL, and (for a server)
    /// the NetBird-SSH flags. macOS/Windows run `up` without sudo.
    private func upLine(_ key: String, _ t: EnrollTarget) -> String {
        let sudo = (t == .serverUbuntu || t == .devUbuntu) ? "sudo " : ""
        let serverFlags = t.isServer ? " --allow-server-ssh --enable-ssh" : ""
        return "\(sudo)netbird up --setup-key \(key) --management-url \(managementURL)\(serverFlags)"
    }

    /// ① Full setup for a machine that does NOT have NetBird yet: install the
    /// client, start the service, then connect.
    private func freshCommand(_ key: String, _ t: EnrollTarget) -> String {
        switch t {
        case .serverUbuntu, .devUbuntu:
            return """
            command -v netbird >/dev/null || curl -fsSL https://pkgs.netbird.io/install.sh | sh
            sudo netbird service install 2>/dev/null || true
            sudo netbird service start  2>/dev/null || true
            \(upLine(key, t))
            """
        case .devMacOS:
            return """
            command -v netbird >/dev/null || brew install netbirdio/tap/netbird
            sudo netbird service install && sudo netbird service start
            \(upLine(key, t))
            """
        case .devWindows:
            // PowerShell, run as Administrator.
            return """
            if (-not (Get-Command netbird -ErrorAction SilentlyContinue)) { winget install --id NetBird.NetBird -e --accept-source-agreements --accept-package-agreements }
            netbird service install 2>$null; netbird service start 2>$null
            \(upLine(key, t))
            """
        }
    }

    /// ② Fast fix for a machine that already has NetBird but is mis-enrolled
    /// (wrong/missing management URL): drop the session and reconnect. No
    /// install, no config wipe — `up` overwrites the registration in place.
    private func quickFixCommand(_ key: String, _ t: EnrollTarget) -> String {
        let down = t.isWindows ? "netbird down" : "sudo netbird down"
        return "\(down)\n\(upLine(key, t))"
    }

    // MARK: sheet

    @ViewBuilder private func keySheet(_ k: NBSetupKey) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Lệnh cài máy mới (\(k.name))").font(.system(size: 13, weight: .semibold))

                Text("Key dùng 1 lần — chỉ enroll được đúng 1 máy. Mỗi máy mới bấm lại nút này để lấy key riêng.")
                    .font(.system(size: 10.5)).foregroundColor(palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("", selection: $target) {
                    ForEach(EnrollTarget.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()

                Text(targetHint)
                    .font(.system(size: 11)).foregroundColor(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                if !target.isWindows {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundColor(palette.gold)
                        Text("Dán cả khối dễ bị sudo nuốt mất các dòng sau khi hỏi mật khẩu. Chạy `sudo -v` (nhập pass 1 lần) trước, rồi mới dán.")
                            .font(.system(size: 10.5)).foregroundColor(palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.gold.opacity(0.12)))
                }

                cmdBlock("① Cài mới — máy chưa có NetBird", freshCommand(k.key, target))
                cmdBlock("② Sửa nhanh — đã cài nhưng lỗi enroll", quickFixCommand(k.key, target))

                if let r = recipient, !r.email.isEmpty {
                    Button { composeEmail(k, to: r) } label: {
                        Label("Soạn email gửi \(r.name) (\(r.email))", systemImage: "envelope")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(palette.moss)
                } else if let r = recipient {
                    Text("\(r.name) chưa có email trong danh bạ — copy lệnh ① gửi tay, hoặc thêm email trong “Quản lý danh bạ”.")
                        .font(.system(size: 10.5)).foregroundColor(palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(target.isServer
                     ? "Sau đó trong app: ＋ Nhóm server → 🖥 Thêm máy."
                     : "Sau đó trong app: “Duyệt & gán” ở banner vàng.")
                    .font(.system(size: 10)).foregroundColor(palette.ink3)
            }
            .padding(16)
        }
        .frame(width: 540, height: 420)
    }

    private var targetHint: String {
        if target.isServer {
            return "Chạy trên VPS Ubuntu. Bật sẵn NetBird SSH (Model B) — dev được cấp quyền vào bằng `netbird ssh`, không cần quản lý khoá."
        }
        if target.isWindows {
            return "Chạy trong PowerShell (Run as Administrator). Máy rơi vào nhóm chờ duyệt; duyệt trong app rồi cấp quyền ở ma trận."
        }
        return "Chạy trên máy dev. Máy rơi vào nhóm chờ duyệt; duyệt trong app rồi cấp quyền ở ma trận."
    }

    @ViewBuilder private func cmdBlock(_ title: String, _ cmd: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(palette.ink)
            Text(cmd)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(palette.paper2))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
            } label: { Label("Copy", systemImage: "doc.on.doc").font(.system(size: 11)) }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }
}
