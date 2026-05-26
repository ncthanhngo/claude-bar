import SwiftUI

/// Diagnostics surface for the Command Center phases. Renders SSH hosts,
/// GitLab instances, Bitwarden lock state, and the last few audit events in
/// one compact card. Each subsection is independent — failures in one
/// section don't break the others.
struct CommandCenterDiagnosticsCard: View {
    private let client = CswClient()

    @State private var sshHosts: [CswClient.SSHHostDTO] = []
    @State private var sshError: String?

    @State private var gitlabInstances: [CswClient.GitLabInstanceDTO] = []
    @State private var gitlabError: String?
    @State private var showAddGitLab = false

    @State private var bwStatus: CswClient.BWStatusDTO?
    @State private var bwError: String?
    @State private var showUnlock = false

    @State private var auditEvents: [CswClient.AuditEventDTO] = []
    @State private var auditError: String?
    @State private var auditPath: String = ""

    var body: some View {
        SettingsGroup("Command Center",
                      subtitle: "SSH hosts, GitLab instances, Bitwarden vault, and the local write audit log.") {
            sshSection
            Divider().opacity(0.3)
            gitlabSection
            Divider().opacity(0.3)
            bitwardenSection
            Divider().opacity(0.3)
            auditSection
        }
        .task { await refreshAll() }
        .sheet(isPresented: $showAddGitLab) {
            GitLabAddSheet(
                onSubmit: { name, base, note, pat in
                    try await client.gitlabAdd(name: name, baseURL: base, note: note, pat: pat)
                    await loadGitLab()
                },
                onDismiss: { showAddGitLab = false }
            )
        }
        .sheet(isPresented: $showUnlock) {
            BitwardenUnlockSheet(onUnlock: { pass in
                Task { try? await client.bwUnlock(passphrase: pass); await loadBW() }
                showUnlock = false
            })
        }
    }

    // MARK: - SSH

    private var sshSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SSH hosts").font(.system(size: 12, weight: .semibold))
                Spacer()
                SettingsBadge(text: "\(sshHosts.count) tracked", color: sshHosts.isEmpty ? .secondary : .green)
                Button("Import ~/.ssh/config") {
                    Task { try? await client.sshImportFromConfig(); await loadSSH() }
                }
                .controlSize(.small)
            }
            if let err = sshError {
                Text(err).font(.caption2).foregroundColor(.red)
            }
            ForEach(sshHosts.prefix(6)) { h in
                HStack(spacing: 6) {
                    Image(systemName: "server.rack").foregroundColor(.secondary)
                    Text(h.name).font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Text(h.hostName ?? "—").font(.caption2).foregroundColor(.secondary)
                    Button {
                        Task { try? await client.sshRemove(name: h.name); await loadSSH() }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            if sshHosts.count > 6 {
                Text("+\(sshHosts.count - 6) more").font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - GitLab

    private var gitlabSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("GitLab instances").font(.system(size: 12, weight: .semibold))
                Spacer()
                SettingsBadge(text: "\(gitlabInstances.count) configured", color: gitlabInstances.isEmpty ? .secondary : .blue)
                Button("Add instance") { showAddGitLab = true }
                    .controlSize(.small)
            }
            if let err = gitlabError {
                Text(err).font(.caption2).foregroundColor(.red)
            }
            ForEach(gitlabInstances) { inst in
                HStack(spacing: 6) {
                    Image(systemName: "circle.hexagongrid").foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(inst.name).font(.system(size: 12, design: .monospaced))
                        Text(inst.baseUrl).font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { try? await client.gitlabRemove(id: inst.id); await loadGitLab() }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Bitwarden

    private var bitwardenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Bitwarden").font(.system(size: 12, weight: .semibold))
                Spacer()
                if let st = bwStatus {
                    SettingsBadge(text: st.unlocked ? "UNLOCKED" : "LOCKED",
                                  color: st.unlocked ? .green : .secondary)
                }
            }
            if let err = bwError {
                Text(err).font(.caption2).foregroundColor(.red)
            }
            if let st = bwStatus, !st.binaryFound {
                Text("`bw` CLI not on PATH — install via `brew install bitwarden-cli`.")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
            HStack {
                Button("Unlock vault…") { showUnlock = true }
                    .controlSize(.small)
                Button("Lock") {
                    Task { try? await client.bwLock(); await loadBW() }
                }
                .controlSize(.small)
                Spacer()
            }
        }
    }

    // MARK: - Audit

    private var auditSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Audit log").font(.system(size: 12, weight: .semibold))
                Spacer()
                SettingsBadge(text: "\(auditEvents.count) recent", color: auditEvents.isEmpty ? .secondary : .green)
                Button("Open log file") {
                    Task {
                        let p = (try? await client.auditPath()) ?? ""
                        if !p.isEmpty {
                            NSWorkspace.shared.open(URL(fileURLWithPath: p))
                        }
                    }
                }
                .controlSize(.small)
            }
            if let err = auditError {
                Text(err).font(.caption2).foregroundColor(.red)
            }
            ForEach(auditEvents.suffix(5).reversed()) { ev in
                HStack(spacing: 6) {
                    Image(systemName: auditIcon(ev.kind)).foregroundColor(.secondary)
                    Text(ev.tool ?? ev.kind).font(.system(size: 11, design: .monospaced))
                    Spacer()
                    Text(ev.outcome).font(.caption2).foregroundColor(outcomeColor(ev.outcome))
                    Text(ev.ts.formatted(.dateTime.hour().minute()))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func auditIcon(_ k: String) -> String {
        switch k {
        case "mcp.write": return "pencil.tip"
        case "gate.cancel": return "xmark.circle"
        case "gate.timeout": return "clock.badge.xmark"
        case "mcp.read-sensitive": return "key.fill"
        case "ssh.exec": return "terminal"
        default: return "doc.text"
        }
    }
    private func outcomeColor(_ o: String) -> Color {
        switch o {
        case "ok": return .green
        case "user_cancelled", "timeout": return .secondary
        default: return .red
        }
    }

    // MARK: - Loaders

    private func refreshAll() async {
        await loadSSH(); await loadGitLab(); await loadBW(); await loadAudit()
    }
    private func loadSSH() async {
        do { sshHosts = try await client.sshList(); sshError = nil } catch { sshError = String(describing: error) }
    }
    private func loadGitLab() async {
        do { gitlabInstances = try await client.gitlabList(); gitlabError = nil } catch { gitlabError = String(describing: error) }
    }
    private func loadBW() async {
        do { bwStatus = try await client.bwStatus(); bwError = nil } catch { bwError = String(describing: error) }
    }
    private func loadAudit() async {
        do {
            auditEvents = try await client.auditTail(lines: 20)
            auditPath = (try? await client.auditPath()) ?? ""
            auditError = nil
        } catch { auditError = String(describing: error) }
    }
}
