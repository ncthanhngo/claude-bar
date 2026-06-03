import SwiftUI

/// Dev × server access matrix — the centerpiece. Rows are DEVS (people),
/// columns are SERVERS (machines). A green 🔑 cell means that dev can SSH into
/// that server (full shell, Model B). Tap a cell to grant/revoke immediately.
struct NetbirdMatrixView: View {
    @ObservedObject var coord: NetbirdCoordinator
    let palette: BriefingPalette

    private let devColWidth: CGFloat = 204
    private let cellWidth: CGFloat = 88

    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    @State private var noteText = ""
    @State private var hoverInfo: String?

    @State private var adding: AddTarget?
    @State private var addText = ""
    @State private var deleteName: String?

    /// Wrapper so an optional group name can drive `.sheet(item:)`.
    private struct RenameTarget: Identifiable { let name: String; var id: String { name } }

    /// Drives the "create empty group" sheet; the role pre-tags the new group
    /// so it lands as a server column or dev row immediately.
    private struct AddTarget: Identifiable { let role: NBGroupRole; var id: String { role.rawValue } }

    /// Hover text listing a group's member machines.
    private func membersHelp(_ group: String) -> String {
        let m = coord.members(ofGroup: group)
        return m.isEmpty ? "\(group): chưa có máy nào" : "\(group): \(m.joined(separator: ", "))"
    }

    /// Menu items for managing a group's member machines: an explicit "remove"
    /// section for current members and an "add" section for the rest. The matrix
    /// axes are GROUPS, so this is how a machine gets filed into a row/column
    /// (server or dev) without leaving the matrix.
    @ViewBuilder private func memberToggles(_ group: String) -> some View {
        let peers = coord.overview?.peers ?? []
        let members = peers.filter { $0.groupNames.contains(group) }
        let others = peers.filter { !$0.groupNames.contains(group) }
        if peers.isEmpty {
            Text("Chưa có máy nào trong mạng.")
        } else {
            if !members.isEmpty {
                Section("Bỏ khỏi nhóm") {
                    ForEach(members) { p in
                        Button { Task { await coord.removePeer(p, fromGroup: group) } } label: {
                            Label(p.name, systemImage: "minus.circle")
                        }
                    }
                }
            }
            Section(members.isEmpty ? "Thêm máy" : "Thêm máy khác") {
                if others.isEmpty {
                    Text("Mọi máy đã ở trong nhóm.")
                } else {
                    ForEach(others) { p in
                        Button { Task { await coord.assignPeer(p, toGroup: group) } } label: {
                            Label(p.name, systemImage: "plus.circle")
                        }
                    }
                }
            }
        }
    }

    private func startRename(_ group: String) {
        renameText = group
        noteText = coord.note(forGroup: group) ?? ""
        renaming = RenameTarget(name: group)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ai vào được máy chủ nào")
                .font(.system(size: 14.5, weight: .bold)).foregroundColor(palette.ink)
            Text("Hàng = dev · Cột = server · ô 🔑 = dev được SSH vào.")
                .font(.system(size: 11)).foregroundColor(palette.ink2)

            // Hover read-out — rê chuột lên tên nhóm/cột để thấy thành viên.
            HStack(spacing: 6) {
                Image(systemName: "person.2").font(.system(size: 10)).foregroundColor(palette.ink3)
                Text(hoverInfo ?? "Rê chuột lên tên nhóm dev / cột server để xem máy bên trong.")
                    .font(.system(size: 11)).foregroundColor(hoverInfo == nil ? palette.ink3 : palette.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.paper2.opacity(0.5)))
            .padding(.bottom, 6)

            addBar

            if coord.servers.isEmpty || coord.devs.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(spacing: 0) {
                        headerRow
                        Rectangle().fill(palette.line).frame(height: 1)
                        ForEach(Array(coord.devs.enumerated()), id: \.element.id) { idx, dev in
                            devRow(dev, index: idx)
                            if dev.id != coord.devs.last?.id {
                                Rectangle().fill(palette.line).frame(height: 1)
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 14).fill(palette.raisedSurface))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.line, lineWidth: 1))
                }
                legend
            }
        }
        .sheet(item: $renaming) { t in renameSheet(t.name) }
        .sheet(item: $adding) { t in addSheet(t.role) }
        .confirmationDialog(
            deleteName.map { "Xoá nhóm “\($0)”?" } ?? "",
            isPresented: Binding(get: { deleteName != nil }, set: { if !$0 { deleteName = nil } }),
            titleVisibility: .visible
        ) {
            Button("Xoá nhóm", role: .destructive) {
                if let n = deleteName { Task { await coord.deleteGroup(name: n) } }
                deleteName = nil
            }
            Button("Huỷ", role: .cancel) { deleteName = nil }
        } message: {
            Text("NetBird sẽ chặn nếu nhóm còn máy hoặc còn policy/route tham chiếu. Gỡ access trong ma trận trước nếu cần.")
        }
    }

    // MARK: create-group bar + sheet

    /// Always-visible so groups can be created even when the matrix is empty
    /// (no servers/devs yet) — the moment that need is highest.
    private var addBar: some View {
        HStack(spacing: 14) {
            Button { addText = ""; adding = AddTarget(role: .server) } label: {
                Label("Nhóm server", systemImage: "plus.circle")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundColor(palette.moss)
            .help("Tạo nhóm server mới")
            Button { addText = ""; adding = AddTarget(role: .dev) } label: {
                Label("Nhóm dev", systemImage: "plus.circle")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundColor(palette.gold)
            .help("Tạo nhóm dev mới")
            Spacer()
        }
        .disabled(coord.busy)
        .padding(.bottom, 6)
    }

    private func addSheet(_ role: NBGroupRole) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(role == .server ? "Thêm nhóm Server" : "Thêm nhóm Dev")
                .font(.system(size: 16, weight: .semibold))
            Text("Tạo nhóm rỗng trên NetBird và gán vai trò \(role == .server ? "Server" : "Dev"). Thêm máy vào nhóm bằng cách duyệt máy chờ hoặc trong NetBird.")
                .font(.system(size: 11)).foregroundColor(palette.ink3)
            TextField(role == .server ? "vd: srv-api" : "vd: dev-an", text: $addText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitAdd(role) }
            if let err = coord.lastError {
                Text(err).font(.system(size: 11)).foregroundColor(palette.coral)
            }
            HStack {
                Spacer()
                Button("Huỷ") { adding = nil }
                Button("Tạo") { commitAdd(role) }
                    .buttonStyle(.borderedProminent)
                    .disabled(addText.trimmingCharacters(in: .whitespaces).isEmpty || coord.busy)
            }
        }
        .padding(20).frame(width: 380)
    }

    private func commitAdd(_ role: NBGroupRole) {
        let name = addText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            await coord.createGroup(name: name, role: role)
            if coord.lastError == nil { addText = ""; adding = nil }
        }
    }

    private func renameSheet(_ group: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Đổi tên nhóm").font(.system(size: 16, weight: .semibold))
            Text("Áp dụng cho cả NetBird; thành viên giữ nguyên.")
                .font(.system(size: 11)).foregroundColor(palette.ink3)
            TextField("Tên nhóm", text: $renameText).textFieldStyle(.roundedBorder)

            // Markdown note — local only (not sent to NetBird), shown on hover.
            VStack(alignment: .leading, spacing: 4) {
                Text("Ghi chú (Markdown)").font(.system(size: 12, weight: .semibold)).foregroundColor(palette.ink2)
                TextEditor(text: $noteText)
                    .font(.system(size: 12))
                    .frame(height: 96)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.paper))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.line, lineWidth: 1))
                Text("Rê chuột lên tên nhóm để xem. Hỗ trợ **đậm**, *nghiêng*, `code`, [link](url), - gạch đầu dòng.")
                    .font(.system(size: 10)).foregroundColor(palette.ink3)
            }

            HStack {
                Spacer()
                Button("Huỷ") { renaming = nil }
                Button("Lưu") {
                    Task {
                        // Save the note under the current name first; renameGroup
                        // then migrates the note key if the name changed.
                        coord.setNote(noteText, for: group)
                        await coord.renameGroup(name: group, to: renameText)
                        renaming = nil
                    }
                }
                .buttonStyle(.borderedProminent).disabled(renameText.isEmpty)
            }
        }
        .padding(20).frame(width: 380)
    }

    // MARK: header (servers)

    private var headerRow: some View {
        HStack(spacing: 0) {
            // Corner: axis labels so server vs dev is unmistakable.
            VStack(alignment: .leading, spacing: 3) {
                Label("SERVER →", systemImage: "server.rack")
                    .font(.system(size: 9, weight: .bold)).foregroundColor(palette.moss)
                Label("↓ DEV", systemImage: "person.fill")
                    .font(.system(size: 9, weight: .bold)).foregroundColor(palette.gold)
            }
            .frame(width: devColWidth, alignment: .leading)

            ForEach(coord.servers) { srv in
                VStack(spacing: 4) {
                    Image(systemName: "server.rack").font(.system(size: 13))
                        .foregroundColor(coord.color(forGroup: srv.groupName) ?? palette.moss)
                    Text(srv.display).font(.system(size: 12, weight: .bold)).foregroundColor(palette.ink)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Circle().fill(srv.online ? palette.sage : palette.ink3).frame(width: 5, height: 5)
                        if coord.note(forGroup: srv.groupName) != nil {
                            Image(systemName: "note.text").font(.system(size: 8)).foregroundColor(palette.ink3)
                        }
                        if let env = envBadge(srv.groupName) {
                            Text(env.0).font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(env.1.opacity(0.16))).foregroundColor(env.1)
                        }
                    }
                    Menu {
                        Section("Máy trong \(srv.display)") { memberToggles(srv.groupName) }
                    } label: {
                        Image(systemName: "desktopcomputer").font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton).fixedSize().frame(height: 16)
                    .foregroundColor(palette.ink3)
                    .help("Thêm / bỏ máy khỏi \(srv.display)")
                }
                .frame(width: cellWidth)
                .contentShape(Rectangle())
                .netbirdNoteHover(coord.note(forGroup: srv.groupName), palette: palette)
                .onHover { hoverInfo = $0 ? membersHelp(srv.groupName) + "  ·  🖥 để thêm máy · chuột phải để đổi tên / xoá" : nil }
                .onTapGesture { startRename(srv.groupName) }
                .contextMenu {
                    Menu("Máy trong nhóm") { memberToggles(srv.groupName) }
                    Button("Đổi tên") { startRename(srv.groupName) }
                    Divider()
                    Button("Xoá nhóm", role: .destructive) { deleteName = srv.groupName }
                }
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(palette.paper2.opacity(0.4))
    }

    // MARK: dev rows

    private func devRow(_ dev: NBNode, index: Int) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 9) {
                avatar(dev.display, group: dev.groupName, index: index)
                Text(dev.display).font(.system(size: 13, weight: .semibold)).foregroundColor(palette.ink)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .netbirdNoteHover(coord.note(forGroup: dev.groupName), palette: palette)
                    .onHover { hoverInfo = $0 ? membersHelp(dev.groupName) : nil }
                if coord.note(forGroup: dev.groupName) != nil {
                    Image(systemName: "note.text").font(.system(size: 9)).foregroundColor(palette.ink3)
                }
                Button { startRename(dev.groupName) } label: {
                    Image(systemName: "pencil").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundColor(palette.ink3)
                .help("Đổi tên nhóm \(dev.display)")
                Menu {
                    Section("Máy trong nhóm \(dev.display)") { memberToggles(dev.groupName) }
                } label: {
                    Image(systemName: "desktopcomputer").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton).fixedSize().frame(width: 24)
                .foregroundColor(palette.ink3)
                .help("Thêm / bỏ máy khỏi nhóm \(dev.display)")
                Spacer(minLength: 4)
                Button { Task { await coord.revokeAllForDev(dev.groupName) } } label: {
                    Image(systemName: "xmark.shield").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundColor(palette.ink3)
                .help("Thu hết quyền của \(dev.display)")
                Button { deleteName = dev.groupName } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundColor(palette.ink3)
                .help("Xoá nhóm \(dev.display)")
            }
            .frame(width: devColWidth, alignment: .leading)

            ForEach(coord.servers) { srv in
                cell(dev: dev, srv: srv).frame(width: cellWidth)
            }
        }
        .padding(.vertical, 11).padding(.horizontal, 16)
    }

    private func cell(dev: NBNode, srv: NBNode) -> some View {
        let on = coord.hasAccess(dev: dev.groupName, server: srv.groupName)
        return Button {
            Task { await coord.setAccess(dev: dev.groupName, server: srv.groupName, on: !on) }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(on ? palette.sage.opacity(0.18) : palette.paper)
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .stroke(on ? palette.sage : palette.line2, lineWidth: 1.5))
                    .frame(width: 34, height: 34)
                if on {
                    Image(systemName: "key.fill").font(.system(size: 13, weight: .bold))
                        .foregroundColor(palette.moss)
                } else {
                    Text("—").font(.system(size: 13)).foregroundColor(palette.ink3.opacity(0.5))
                }
            }
        }
        .buttonStyle(.plain).disabled(coord.busy)
        .help(on ? "\(dev.display) được SSH vào \(srv.display) — toàn quyền shell. Bấm để thu."
                 : "Bấm để cho \(dev.display) SSH vào \(srv.display).")
    }

    // MARK: bits

    private var legend: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill").font(.system(size: 11)).foregroundColor(palette.moss)
                Text("Được SSH (toàn quyền shell)").font(.system(size: 11)).foregroundColor(palette.ink2)
            }
            HStack(spacing: 6) {
                Text("—").font(.system(size: 12)).foregroundColor(palette.ink3)
                Text("Không vào được").font(.system(size: 11)).foregroundColor(palette.ink2)
            }
            Spacer()
            if coord.busy { ProgressView().scaleEffect(0.6) }
        }
        .padding(.horizontal, 4).padding(.top, 4)
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.3x3").foregroundColor(palette.ink3)
            Text(coord.servers.isEmpty && coord.devs.isEmpty
                 ? "Chưa có nhóm Server/Dev. Bấm ＋ ở trên để tạo nhóm, hoặc ⚙ để gán vai trò cho nhóm sẵn có."
                 : coord.devs.isEmpty
                   ? "Chưa có nhóm Dev. Bấm ＋ Nhóm dev ở trên, duyệt máy chờ, hoặc ⚙ để gán một nhóm là Dev."
                   : "Chưa có nhóm Server. Bấm ＋ Nhóm server ở trên, hoặc ⚙ để gán một nhóm là Server.")
                .font(.system(size: 12)).foregroundColor(palette.ink2)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.raisedSurface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
    }

    private func avatar(_ name: String, group: String, index: Int) -> some View {
        let fallback = [palette.coral, palette.plum, palette.gold, palette.moss, palette.sage, palette.rose]
        let c = coord.color(forGroup: group) ?? fallback[index % fallback.count]
        return Text(String(name.prefix(1)).uppercased())
            .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
            .frame(width: 28, height: 28).background(Circle().fill(c))
    }

    private func envBadge(_ name: String) -> (String, Color)? {
        let n = name.lowercased()
        if n.contains("prod") { return ("PROD", palette.coral) }
        if n.contains("stag") { return ("STG", palette.plum) }
        if n.contains("ci") { return ("CI", palette.gold) }
        return nil
    }
}
