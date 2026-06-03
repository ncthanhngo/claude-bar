import SwiftUI

/// Workspace → Netbird zone. Self-contained: owns its NetbirdCoordinator so it
/// can be dropped into BriefingView's body stage without touching the window
/// controller's injection plumbing. Shows a config prompt until a token is
/// saved, then the live panel (stats · pending · access matrix · peer list).
struct NetbirdModeBody: View {
    let palette: BriefingPalette
    @StateObject private var coord = NetbirdCoordinator()
    @State private var showRoles = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                netbirdSection
                Rectangle().fill(palette.line).frame(height: 1)
                SSHManagerView(palette: palette, meshServers: meshServers)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .task {
            coord.start()
            // Auto-refresh while the panel is on screen so online status and
            // access changes (incl. from other admins) don't go stale. Skipped
            // while a mutation is in flight to avoid clobbering optimistic state.
            // Cancelled automatically when the view disappears.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000) // 20s
                if !coord.busy { await coord.load() }
            }
        }
    }

    @ViewBuilder private var netbirdSection: some View {
        if coord.isLoading && coord.overview == nil {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        } else if !coord.configured {
            NetbirdConfigPrompt(palette: palette, coord: coord).frame(minHeight: 220)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                header
                NetbirdStatStrip(coord: coord, palette: palette)
                if let err = coord.lastError {
                    Text(err)
                        .font(.system(size: 12)).foregroundColor(palette.coral)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(palette.coral.opacity(0.08)))
                }
                if !coord.pending.isEmpty {
                    NetbirdPendingView(coord: coord, palette: palette)
                }
                // Matrix (access) on the left, machine list on the right so the
                // right half isn't left empty at Medium window size. The matrix
                // scrolls horizontally inside its half when servers (columns)
                // outgrow the width, so adding servers never squeezes the list.
                HStack(alignment: .top, spacing: 16) {
                    NetbirdMatrixView(coord: coord, palette: palette)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    Rectangle().fill(palette.line).frame(width: 1)
                    NetbirdPeerListView(coord: coord, palette: palette)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                NetbirdExternalPoliciesView(coord: coord, palette: palette)
            }
        }
    }

    /// Mesh servers offered to the SSH pane for one-click import.
    private var meshServers: [(name: String, host: String, user: String)] {
        coord.servers.compactMap { node in
            guard let p = node.peer else { return nil }
            let host = p.dnsLabel.isEmpty ? p.ip : p.dnsLabel
            return (name: node.display, host: host, user: "deploy")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Mạng & quyền truy cập")
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .foregroundColor(palette.ink)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                NetbirdSetupKeyButton(coord: coord, palette: palette)
                NetbirdSetupKeysButton(coord: coord, palette: palette)
                iconButton("gearshape", help: "Phân loại nhóm (server / dev)") {
                    showRoles.toggle()
                }
                .popover(isPresented: $showRoles, arrowEdge: .bottom) {
                    NetbirdGroupRolesView(coord: coord, palette: palette)
                        .frame(width: 460)
                        .padding(16)
                }
                iconButton("arrow.clockwise", help: "Làm mới") {
                    Task { await coord.load() }
                }
                .disabled(coord.busy)
            }
        }
    }

    /// Square icon-only toolbar button with a subtle pill background so the
    /// header reads as one tidy control cluster instead of loose glyphs.
    private func iconButton(_ systemName: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 13, weight: .semibold))
                .foregroundColor(palette.ink2)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.raisedSurface))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// First-run prompt: paste a NetBird PAT/service-user token + optional base URL.
struct NetbirdConfigPrompt: View {
    let palette: BriefingPalette
    @ObservedObject var coord: NetbirdCoordinator
    @State private var token = ""
    @State private var baseURL = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 34)).foregroundColor(palette.gold)
            Text("Kết nối NetBird").font(.system(size: 20, weight: .semibold))
                .foregroundColor(palette.ink)
            Text("Dán Personal Access Token (scope admin) từ self-host của bạn.")
                .font(.system(size: 13)).foregroundColor(palette.ink2)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 6) {
                TextField("netbird.evselab.com", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                Text("Chỉ cần nhập tên miền — app tự thêm https:// và /api.")
                    .font(.system(size: 11)).foregroundColor(palette.ink3)
                SecureField("Token", text: $token)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(width: 360)

            if let err = coord.lastError {
                Text(err).font(.system(size: 12)).foregroundColor(palette.coral)
                    .frame(width: 360, alignment: .leading)
            }

            Button {
                Task { await coord.saveConfig(baseURL: baseURL, token: token) }
            } label: {
                Text(coord.busy ? "Đang kiểm tra…" : "Lưu & kết nối")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(token.isEmpty || coord.busy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
