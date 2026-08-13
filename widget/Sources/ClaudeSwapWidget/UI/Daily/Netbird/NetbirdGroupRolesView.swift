import SwiftUI

/// Lets the admin tag each NetBird group as Server or Dev (or leave it out).
/// NetBird group names are arbitrary (VPS, private-servers…), so this mapping —
/// not a naming convention — drives the matrix rows/cols. Auto-expands while no
/// roles are set so a fresh instance has an obvious next step.
struct NetbirdGroupRolesView: View {
    @ObservedObject var coord: NetbirdCoordinator
    let palette: BriefingPalette

    @State private var showAdd = false
    @State private var newName = ""
    @State private var newRole: NBGroupRole = .server

    private var groups: [NBGroup] {
        (coord.overview?.groups ?? [])
            .filter { !NetbirdCoordinator.reservedGroups.contains($0.name) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2").font(.system(size: 12)).foregroundColor(palette.ink2)
                Text("Phân loại nhóm")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(palette.ink)
                Spacer()
                Button { withAnimation { showAdd.toggle() } } label: {
                    Image(systemName: showAdd ? "xmark.circle" : "plus.circle")
                        .font(.system(size: 14)).foregroundColor(palette.ink2)
                }
                .buttonStyle(.plain)
                .help(showAdd ? "Huỷ" : "Tạo nhóm mới")
                .disabled(coord.busy)
            }
            Text("Gán nhóm nào là Server / Dev để dựng ma trận. Tự đoán theo tên, sửa được.")
                .font(.system(size: 11)).foregroundColor(palette.ink3)
                .padding(.bottom, 6)
            if showAdd { addRow }
            VStack(spacing: 0) {
                ForEach(groups) { g in
                    GroupRoleRow(coord: coord, palette: palette, group: g)
                    if g.id != groups.last?.id { Rectangle().fill(palette.line).frame(height: 1) }
                }
                if groups.isEmpty {
                    Text("Chưa có nhóm nào (ngoài All / dev-pending).")
                        .font(.system(size: 12)).foregroundColor(palette.ink3)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    /// Inline "create empty group" form: name + Server/Dev role, committed to
    /// NetBird via the coordinator. The new group is tagged with `newRole`
    /// locally so it lands directly in the matrix.
    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("tên nhóm mới", text: $newName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .onSubmit { commitAdd() }
            Picker("", selection: $newRole) {
                Text("Server").tag(NBGroupRole.server)
                Text("Dev").tag(NBGroupRole.dev)
            }
            .pickerStyle(.segmented).frame(width: 140).labelsHidden()
            Button("Tạo") { commitAdd() }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || coord.busy)
        }
        .padding(.vertical, 6)
    }

    private func commitAdd() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let role = newRole
        Task {
            await coord.createGroup(name: name, role: role)
            if coord.lastError == nil {
                newName = ""
                withAnimation { showAdd = false }
            }
        }
    }
}

/// One editable group row: rename inline (commit on Enter) + role picker.
private struct GroupRoleRow: View {
    @ObservedObject var coord: NetbirdCoordinator
    let palette: BriefingPalette
    let group: NBGroup
    @State private var name = ""
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(coord.color(forGroup: group.name) ?? palette.ink3.opacity(0.4))
                    .frame(width: 10, height: 10)
                TextField("tên nhóm", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .onSubmit { Task { await coord.renameGroup(id: group.id, oldName: group.name, to: name) } }
                Text("\(group.peersCount) máy").font(.system(size: 11)).foregroundColor(palette.ink3)
                Spacer()
                Picker("", selection: Binding(
                    get: { coord.roles[group.name] },
                    set: { coord.setRole($0, for: group.name) }
                )) {
                    Text("—").tag(NBGroupRole?.none)
                    Text("Server").tag(NBGroupRole?.some(.server))
                    Text("Dev").tag(NBGroupRole?.some(.dev))
                }
                .pickerStyle(.segmented).frame(width: 180).labelsHidden()
                Button { confirmDelete = true } label: {
                    Image(systemName: "trash").font(.system(size: 12)).foregroundColor(palette.ink3)
                }
                .buttonStyle(.plain)
                .help("Xoá nhóm")
                .disabled(coord.busy)
            }
            swatchRow
        }
        .padding(.vertical, 8)
        .onAppear { name = group.name }
        .confirmationDialog("Xoá nhóm “\(group.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Xoá nhóm", role: .destructive) {
                Task { await coord.deleteGroup(name: group.name) }
            }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("NetBird sẽ chặn nếu nhóm còn máy hoặc còn policy/route tham chiếu. Gỡ access trong ma trận trước nếu cần.")
        }
    }

    private var swatchRow: some View {
        HStack(spacing: 7) {
            ForEach(NetbirdColorsStore.swatches, id: \.self) { hex in
                let selected = coord.colors[group.name] == hex
                Circle().fill(Color(hex: hex))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(palette.ink, lineWidth: selected ? 2 : 0))
                    .overlay(Circle().stroke(palette.line, lineWidth: selected ? 0 : 1))
                    .onTapGesture { coord.setColor(selected ? nil : hex, for: group.name) }
            }
            Spacer()
        }
        .padding(.leading, 18)
    }
}
